import Foundation

actor ClaudeAPI {
    static let apiKeyAccount = "anthropic-api-key"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let anthropicVersion = "2023-06-01"

    enum APIError: Error, CustomStringConvertible {
        case missingAPIKey
        case http(Int, String)
        case decoding(String)
        case noToolUseInResponse
        case cliMissing
        case cliFailed(Int32, String)
        case cliOutputParse(String)

        var description: String {
            switch self {
            case .missingAPIKey:
                return "Anthropic API key not set. Add one in Settings → AI Suggestions."
            case .http(let code, let body):
                return "Anthropic API error \(code): \(body)"
            case .decoding(let msg):
                return "Failed to decode response: \(msg)"
            case .noToolUseInResponse:
                return "Model did not return a tool_use block."
            case .cliMissing:
                return "Claude Code CLI not found. Install Claude Code (npm i -g @anthropic-ai/claude-code) or switch to API key mode in Settings."
            case .cliFailed(let code, let stderr):
                return "claude CLI exited with status \(code): \(stderr)"
            case .cliOutputParse(let msg):
                return "Could not parse JSON from claude CLI output: \(msg)"
            }
        }
    }

    struct ToolDefinition {
        let name: String
        let description: String
        let inputSchema: [String: Any]
    }

    /// Routes to API or CLI depending on AppSettings.aiAuthMode.
    func callTool(model: String,
                  systemPrompt: String,
                  userPrompt: String,
                  tool: ToolDefinition,
                  maxTokens: Int = 4096) async throws -> [String: Any] {
        switch AppSettings.aiAuthMode {
        case .apiKey:
            return try await callToolViaAPI(model: model,
                                            systemPrompt: systemPrompt,
                                            userPrompt: userPrompt,
                                            tool: tool,
                                            maxTokens: maxTokens)
        case .claudeCodeCLI:
            return try await callToolViaCLI(model: model,
                                            systemPrompt: systemPrompt,
                                            userPrompt: userPrompt,
                                            tool: tool)
        }
    }

    private func callToolViaAPI(model: String,
                                systemPrompt: String,
                                userPrompt: String,
                                tool: ToolDefinition,
                                maxTokens: Int) async throws -> [String: Any] {
        guard let apiKey = KeychainStore.getData(account: Self.apiKeyAccount)
            .flatMap({ String(data: $0, encoding: .utf8) })
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ],
            "tools": [[
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema
            ]],
            "tool_choice": ["type": "tool", "name": tool.name]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(0, String(data: data, encoding: .utf8) ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data, encoding: .utf8) ?? ""
            let trimmed = preview.count > 600 ? String(preview.prefix(600)) + "…" : preview
            throw APIError.http(http.statusCode, trimmed)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw APIError.decoding("response shape unexpected")
        }

        let toolBlock = content.first { ($0["type"] as? String) == "tool_use" }
        guard let toolBlock,
              let input = toolBlock["input"] as? [String: Any] else {
            throw APIError.noToolUseInResponse
        }
        return input
    }

    private func callToolViaCLI(model: String,
                                systemPrompt: String,
                                userPrompt: String,
                                tool: ToolDefinition) async throws -> [String: Any] {
        guard let claudePath = ClaudeCLIDetector.findClaudeBinary() else {
            throw APIError.cliMissing
        }

        // Compose a prompt that asks the model to produce JSON matching the same
        // schema we use for the API's tool_use mode. The CLI doesn't expose
        // tool_use to us, so we instruct + parse.
        let schemaJSON: String = {
            if let data = try? JSONSerialization.data(withJSONObject: tool.inputSchema, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        }()
        let composed = """
        \(systemPrompt)

        ---

        \(userPrompt)

        ---

        Respond with ONLY a single JSON object matching the schema below,
        wrapped in a ```json fenced block. Do not include any prose before
        or after the JSON block.

        Schema:
        ```json
        \(schemaJSON)
        ```
        """

        let result = try await runCLI(executable: claudePath, prompt: composed, model: model)
        return try extractJSONObject(from: result)
    }

    private func runCLI(executable: String, prompt: String, model: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = ["-p", prompt,
                                  "--output-format", "json",
                                  "--model", model]

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                // Inherit env so the user's auth is found, plus TM_SKIP_HOOKS so
                // our own tm-hook short-circuits on this internal invocation.
                var env = ProcessInfo.processInfo.environment
                env["TM_SKIP_HOOKS"] = "1"
                proc.environment = env

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                proc.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if proc.terminationStatus != 0 {
                    let preview = stderr.isEmpty ? stdout : stderr
                    let trimmed = preview.count > 600 ? String(preview.prefix(600)) + "…" : preview
                    cont.resume(throwing: APIError.cliFailed(proc.terminationStatus, trimmed))
                    return
                }

                // Try wrapper JSON first (`--output-format json` returns { result: "..." }).
                if let data = stdout.data(using: .utf8),
                   let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let inner = wrapper["result"] as? String {
                    cont.resume(returning: inner)
                    return
                }
                // Otherwise just hand back stdout as-is.
                cont.resume(returning: stdout)
            }
        }
    }

    /// Extracts a JSON object from arbitrary model text. Tries direct decode,
    /// then ```json fences, then the largest balanced {...} substring.
    private func extractJSONObject(from text: String) throws -> [String: Any] {
        // 1. Direct decode.
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // 2. ```json ... ``` fenced block.
        if let fenced = firstFencedJSON(in: text),
           let data = fenced.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // 3. Largest balanced {...} region.
        if let braced = firstBalancedBraces(in: text),
           let data = braced.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        let preview = text.count > 400 ? String(text.prefix(400)) + "…" : text
        throw APIError.cliOutputParse(preview)
    }

    private func firstFencedJSON(in text: String) -> String? {
        // Match ```json … ``` or ``` … ``` (greedy enough to capture the whole thing).
        let patterns = ["```json\\s*([\\s\\S]*?)```", "```\\s*([\\s\\S]*?)```"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: text) {
                return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func firstBalancedBraces(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
