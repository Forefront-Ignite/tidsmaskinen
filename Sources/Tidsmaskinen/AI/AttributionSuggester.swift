import Foundation

struct AttributionSuggester {
    let api: ClaudeAPI

    struct InputSignal: Equatable {
        let id: String
        let kind: AppDatabase.SignalAggregate.Kind
        let value: String
        let totalSeconds: Double
    }

    struct Suggestion: Equatable, Identifiable {
        let signalID: String
        let kindRaw: String
        let signalValue: String
        let customerName: String
        let isNewCustomer: Bool
        let projectName: String?
        let projectIsNew: Bool
        let rulePattern: String
        let confidence: Double
        let reasoning: String

        var id: String { signalID }
    }

    enum SuggesterError: Error, CustomStringConvertible {
        case noUnassignedSignals
        case decoding(String)

        var description: String {
            switch self {
            case .noUnassignedSignals: return "No unassigned signals to suggest for."
            case .decoding(let m): return "Failed to decode model suggestions: \(m)"
            }
        }
    }

    /// Asks Claude to map a batch of unassigned signals to existing or new customers/projects.
    func suggest(signals: [InputSignal],
                 customers: [Customer],
                 projects: [Project],
                 rules: [Rule],
                 model: String = AppSettings.aiModel,
                 userDomain: String = "forefront.se") async throws -> [Suggestion] {
        guard !signals.isEmpty else { throw SuggesterError.noUnassignedSignals }

        let systemPrompt = """
        You are helping a software engineer at Forefront (a Swedish consultancy) categorize their work signals into customers and projects for a weekly timesheet.

        Their own work email domain is `\(userDomain)` — any meeting attendee at that domain is internal, not a customer.

        Map each signal to the most likely customer, creating new customers when none of the existing ones fit. For Git repo signals, also choose or create a project (multiple repos per customer is common — different repos usually mean different projects). For other signal kinds, leave project null unless the signal clearly indicates one.

        Be conservative with confidence: 0.9+ only for unambiguous matches (e.g. domain explicitly matches a known customer). Set lower scores for guesses. Provide a one-sentence reasoning for each.

        Return rule_pattern in the form the matching engine expects:
        - gitRepoSlug: glob like `owner/*` or exact `owner/repo`
        - urlHost: glob like `*.example.com` or exact `app.example.com`
        - urlPath: glob against `host/path`, typically prefix-style like `github.com/forefront/foo*`
        - appBundleID: exact bundle ID
        - meetingDomain (matches as emailDomain): exact domain like `acme.com`
        """

        let userPrompt = buildUserPrompt(signals: signals,
                                         customers: customers,
                                         projects: projects,
                                         rules: rules)

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "suggestions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "signal_id":        ["type": "string"],
                            "customer_name":    ["type": "string"],
                            "is_new_customer":  ["type": "boolean"],
                            "project_name":     ["type": ["string", "null"]],
                            "project_is_new":   ["type": "boolean"],
                            "rule_pattern":     ["type": "string"],
                            "confidence":       ["type": "number"],
                            "reasoning":        ["type": "string"]
                        ],
                        "required": ["signal_id", "customer_name", "is_new_customer",
                                     "project_is_new", "rule_pattern", "confidence", "reasoning"]
                    ]
                ]
            ],
            "required": ["suggestions"]
        ]

        let tool = ClaudeAPI.ToolDefinition(
            name: "submit_attributions",
            description: "Submit attribution suggestions for the listed signals.",
            inputSchema: schema
        )

        let response = try await api.callTool(
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            tool: tool,
            maxTokens: 4096
        )

        guard let array = response["suggestions"] as? [[String: Any]] else {
            throw SuggesterError.decoding("missing suggestions[] in response")
        }

        let inputByID = Dictionary(uniqueKeysWithValues: signals.map { ($0.id, $0) })
        var out: [Suggestion] = []
        for item in array {
            guard let signalID = item["signal_id"] as? String,
                  let customerName = item["customer_name"] as? String,
                  let isNewCustomer = item["is_new_customer"] as? Bool,
                  let projectIsNew = item["project_is_new"] as? Bool,
                  let rulePattern = item["rule_pattern"] as? String,
                  let confidence = (item["confidence"] as? Double)
                    ?? (item["confidence"] as? Int).map(Double.init),
                  let reasoning = item["reasoning"] as? String
            else { continue }
            let input = inputByID[signalID]
            let projectName = (item["project_name"] as? String)?.trimmingCharacters(in: .whitespaces)
            out.append(Suggestion(
                signalID: signalID,
                kindRaw: input?.kind.rawValue ?? "unknown",
                signalValue: input?.value ?? signalID,
                customerName: customerName.trimmingCharacters(in: .whitespaces),
                isNewCustomer: isNewCustomer,
                projectName: (projectName?.isEmpty == false) ? projectName : nil,
                projectIsNew: projectIsNew,
                rulePattern: rulePattern.trimmingCharacters(in: .whitespaces),
                confidence: confidence,
                reasoning: reasoning
            ))
        }
        return out
    }

    private func buildUserPrompt(signals: [InputSignal],
                                 customers: [Customer],
                                 projects: [Project],
                                 rules: [Rule]) -> String {
        var lines: [String] = []

        if customers.isEmpty {
            lines.append("Existing customers: (none yet — feel free to suggest new ones)")
        } else {
            lines.append("Existing customers:")
            for c in customers.sorted(by: { $0.name < $1.name }) {
                let projs = projects.filter { $0.customerID == c.id }
                if projs.isEmpty {
                    lines.append("  - \(c.name)")
                } else {
                    let projNames = projs.map { $0.name }.sorted().joined(separator: ", ")
                    lines.append("  - \(c.name) [projects: \(projNames)]")
                }
            }
        }
        lines.append("")

        if !rules.isEmpty {
            lines.append("Existing rules (precedents):")
            let customersByID = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
            let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            for r in rules.prefix(40) {
                let cust = customersByID[r.customerID]?.name ?? "?"
                let proj = r.projectID.flatMap { projectsByID[$0]?.name }
                let target = proj.map { "\(cust) · \($0)" } ?? cust
                lines.append("  - \(r.kind.rawValue) `\(r.pattern)` → \(target)")
            }
            lines.append("")
        }

        lines.append("Unassigned signals (sorted by time spent):")
        for s in signals.prefix(40) {
            let hours = s.totalSeconds / 3600.0
            let label = String(format: "%.1fh", hours)
            lines.append("  - id=\(s.id), kind=\(s.kind.rawValue), value=`\(s.value)`, time=\(label)")
        }
        lines.append("")
        lines.append("Return a suggestions array — one entry per signal id above.")
        return lines.joined(separator: "\n")
    }
}
