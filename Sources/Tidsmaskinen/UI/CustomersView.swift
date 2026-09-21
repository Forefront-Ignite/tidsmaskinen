import SwiftUI

struct CustomersView: View {
    @EnvironmentObject private var state: AppState
    @State private var customers: [Customer] = []
    @State private var rules: [Rule] = []
    @State private var customerProjects: [Project] = []
    @State private var selectedCustomerID: String?
    @State private var newCustomerName: String = ""
    @State private var newProjectName: String = ""
    @State private var ruleSheet: RuleEdit?
    @State private var allRules: [Rule] = []
    @State private var groupPendingPermanent: RuleStack?
    @State private var loadError: String?
    @State private var customerPendingDeletion: Customer?

    /// What the rule sheet edits: a new rule or an existing one.
    struct RuleEdit: Identifiable {
        let rule: Rule?
        var id: String { rule?.id ?? "new" }
    }

    /// Every rule for one (kind, pattern) of the selected customer. Several
    /// week-bounded rules on the same pattern are one stack, drawn as one row.
    struct RuleStack: Identifiable {
        let kind: Rule.Kind
        let pattern: String
        let rules: [Rule]          // newest first
        var id: String { "\(kind.rawValue):\(pattern)" }
        var permanent: Rule? { rules.first { !$0.isTemporary } }
        var bounded: [Rule] { rules.filter(\.isTemporary) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Customers").font(.system(size: 24, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            if state.commandCenterTokenInvalid {
                tokenInvalidBanner
            }
            HSplitView {
                customerSidebar
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                customerDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            reload()
            // Debounced refresh: only nudge a sync if the last one is stale.
            if AppSettings.commandCenterEnabled,
               state.commandCenterHasToken,
               !state.commandCenterTokenInvalid,
               shouldDebouncedRefresh() {
                Task { await state.refreshCommandCenter() }
            }
        }
        .onChange(of: selectedCustomerID) { _, _ in reload() }
        .onChange(of: state.commandCenterLastSyncAt) { _, _ in reload() }
        .alert("Database error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .confirmationDialog(
            "Delete “\(customerPendingDeletion?.name ?? "")”?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete customer", role: .destructive) {
                if let c = customerPendingDeletion { delete(c) }
                customerPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { customerPendingDeletion = nil }
        } message: {
            Text("Its local projects and rules are removed too. This can't be undone.")
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(get: { customerPendingDeletion != nil },
                set: { if !$0 { customerPendingDeletion = nil } })
    }

    @ViewBuilder
    private var tokenInvalidBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Command Center token rejected — update it in Settings.")
                .font(.callout)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red)
    }

    private func shouldDebouncedRefresh() -> Bool {
        guard let last = state.commandCenterLastSyncAt else { return true }
        return Date().timeIntervalSince(last) > 5 * 60
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    @ViewBuilder
    private var customerSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedCustomerID) {
                let external = customers.filter(\.isExternal), local = customers.filter { !$0.isExternal }
                if !external.isEmpty {
                    Section { ForEach(external) { customer in sidebarRow(customer) } }
                        header: { sectionHeader("From Command Center", count: external.count) }
                }
                Section { ForEach(local) { customer in sidebarRow(customer) } }
                    header: { sectionHeader("Local", count: local.count) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                TextField("New customer name", text: $newCustomerName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCustomer() }
                Button("Add") { addCustomer() }
                    .disabled(newCustomerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ customer: Customer) -> some View {
        CustomerSidebarRow(customer: customer) {
            customerPendingDeletion = customer
        }
        .tag(customer.id)
        .contextMenu {
            if customer.isExternal {
                Text("Synced from Command Center").foregroundStyle(.secondary)
            } else {
                Button("Delete", role: .destructive) { customerPendingDeletion = customer }
            }
        }
    }

    @ViewBuilder
    private var customerDetail: some View {
        if let customerID = selectedCustomerID,
           let customer = customers.first(where: { $0.id == customerID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        ColorDot(color: Color(hex: customer.displayColor) ?? .blue, size: 14)
                        Text(customer.name)
                            .font(.system(size: 21, weight: .bold))
                        SourceChip(isCommandCenter: customer.isExternal)
                        Spacer()
                        if customer.isExternal {
                            Label("Name, colour and projects are managed in Command Center", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            ruleSheet = RuleEdit(rule: nil)
                        } label: {
                            Label("Add rule", systemImage: "plus")
                        }
                    }

                    projectsSection(for: customer)
                    rulesSection(for: customer)
                }
                .padding(26)
            }
            .sheet(item: $ruleSheet) { edit in
                AddRuleSheet(
                    customerID: customer.id,
                    availableProjects: customerProjects,
                    existing: edit.rule,
                    database: state.database
                ) { rule in
                    // Same (kind, pattern, window) replaces rather than duplicates.
                    try state.database.upsertReplacingWindow(rule)
                    reload()
                }
            }
            .confirmationDialog(
                "Make “\(groupPendingPermanent?.pattern ?? "")” permanent?",
                isPresented: Binding(get: { groupPendingPermanent != nil }, set: { if !$0 { groupPendingPermanent = nil } }),
                titleVisibility: .visible
            ) {
                Button("Replace \(groupPendingPermanent?.bounded.count ?? 0) week-bounded rules") {
                    if let g = groupPendingPermanent { makePermanent(g, customer: customer) }
                    groupPendingPermanent = nil
                }
                Button("Cancel", role: .cancel) { groupPendingPermanent = nil }
            } message: {
                Text(makePermanentPreview(groupPendingPermanent))
            }
        } else {
            ContentUnavailableView(
                "No customer selected",
                systemImage: "person.2",
                description: Text("Add a customer in the sidebar to start mapping activity.")
            )
        }
    }

    @ViewBuilder
    private func projectsSection(for customer: Customer) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader("Projects", count: customerProjects.count)

            if customerProjects.isEmpty {
                Text(customer.isExternal
                     ? "No projects synced from Command Center yet."
                     : "No projects yet. Add one below to attribute work at the project level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(customerProjects.enumerated()), id: \.element.id) { idx, project in
                        if idx > 0 { Divider().opacity(0.4) }
                        projectRow(project, customerIsExternal: customer.isExternal)
                    }
                }
                .glassCard(radius: 14)
            }

            if !customer.isExternal {
                HStack {
                    TextField("New project name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addProject(under: customer) }
                    Button("Add project") { addProject(under: customer) }
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project, customerIsExternal: Bool) -> some View {
        HStack(spacing: 11) {
            ColorDot(color: Color(hex: project.displayColor) ?? .blue, size: 9)
            Text(project.name).font(.system(size: 14))
            if project.isExternal { SourceChip(isCommandCenter: true) }
            Spacer()
            if !project.isExternal, !customerIsExternal {
                Button(role: .destructive) {
                    delete(project)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete project — any rules pointing to it become customer-level.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Rule-kind groups shown under "Learned rules" (no priority column).
    private struct RuleGroup { let title: String; let icon: String; let kinds: [Rule.Kind] }
    private static let ruleGroups: [RuleGroup] = [
        .init(title: "Repositories", icon: "chevron.left.forwardslash.chevron.right", kinds: [.gitRepoSlug, .gitRemoteHost]),
        .init(title: "Browser URLs", icon: "globe", kinds: [.urlHost, .urlPath]),
        .init(title: "Apps", icon: "app", kinds: [.appBundleID]),
        .init(title: "Window titles", icon: "macwindow", kinds: [.windowTitle]),
        .init(title: "Slack channels", icon: "number", kinds: [.slackChannel]),
        .init(title: "Call participants", icon: "person.crop.circle", kinds: [.participant]),
    ]

    /// This customer's rules grouped by (kind, pattern), newest first.
    private var ruleStacks: [RuleStack] {
        let grouped = Dictionary(grouping: rules) { "\($0.kind.rawValue):\($0.pattern)" }
        return grouped.values.map { rs in
            let sorted = rs.sorted { $0.createdAt > $1.createdAt }
            return RuleStack(kind: sorted[0].kind, pattern: sorted[0].pattern, rules: sorted)
        }
        .sorted { $0.pattern < $1.pattern }
    }

    /// (kind, pattern) keys of this customer that another customer also claims.
    /// The most specific rule wins at match time, so these decide hours silently.
    private var conflictingKeys: Set<String> {
        let mine = Set(rules.map { "\($0.kind.rawValue):\($0.pattern)" })
        let selected = selectedCustomerID
        return Set(allRules.filter { $0.customerID != selected }
            .map { "\($0.kind.rawValue):\($0.pattern)" }
            .filter { mine.contains($0) })
    }

    private var conflictingPatterns: [String] {
        conflictingKeys.map { String($0.split(separator: ":", maxSplits: 1)[1]) }.sorted()
    }

    @ViewBuilder
    private func rulesSection(for customer: Customer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Learned rules", count: rules.count)

            if !conflictingPatterns.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(conflictingPatterns.count) pattern\(conflictingPatterns.count == 1 ? " is" : "s are") also claimed by another customer: \(conflictingPatterns.joined(separator: ", ")). The most specific rule wins, so these decide hours silently — narrow one side to a path or a week.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 10))
            }

            if rules.isEmpty {
                Text("No rules yet. Confirm a repo, URL or app in Review — or click “Add rule” — and it’ll be remembered here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .glassCard(radius: 14)
            } else {
                ForEach(Self.ruleGroups, id: \.title) { group in
                    let stacks = ruleStacks.filter { group.kinds.contains($0.kind) }
                    if !stacks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(group.title, systemImage: group.icon)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(Array(stacks.enumerated()), id: \.element.id) { idx, stack in
                                    if idx > 0 { Divider().opacity(0.4) }
                                    stackRow(stack, customer: customer)
                                }
                            }
                            .glassCard(radius: 14)
                        }
                    }
                }
            }
        }
    }

    /// One pattern: its permanent rule and/or its stack of week-bounded rules,
    /// described in words (what matches, when, what wins) instead of a
    /// priority number.
    @ViewBuilder
    private func stackRow(_ stack: RuleStack, customer: Customer) -> some View {
        let lead = stack.rules[0]
        let conflict = conflictingKeys.contains(stack.id)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stack.pattern)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if conflict {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                            .help("Another customer also claims this pattern")
                    }
                }
                Text(stackDescription(stack))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(projectName(for: lead.projectID) ?? customer.name)
                .font(.system(size: 13))
                .foregroundStyle(lead.projectID == nil ? .secondary : .primary)
                .lineLimit(1)
            if stack.permanent == nil, !stack.bounded.isEmpty {
                Button("Make permanent") { groupPendingPermanent = stack }
                    .controlSize(.small)
            }
            Menu {
                if stack.rules.count == 1 {
                    Button("Edit…") { ruleSheet = RuleEdit(rule: lead) }
                }
                Button(stack.rules.count == 1 ? "Delete" : "Delete all \(stack.rules.count)", role: .destructive) {
                    for r in stack.rules { delete(r) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Rule actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// "always · most specific wins" / "week 33, week 35 only" / "always · overridden in week 23".
    private func stackDescription(_ stack: RuleStack) -> String {
        var parts: [String] = []
        if stack.permanent != nil { parts.append("always") }
        let bounded = stack.bounded
        if !bounded.isEmpty {
            let weeks = Set(bounded.compactMap { r -> String? in
                guard let from = r.validFrom else { return nil }
                if ruleScopeLabel(r) == "today" { return DateFormatting.weekdayDayShortMonth.string(from: from) }
                return "week \(Calendar.weekStartingMonday().component(.weekOfYear, from: from))"
            }).sorted()
            // A bounded rule beside a permanent one is an override for its window.
            parts.append(stack.permanent == nil ? weeks.joined(separator: ", ") + " only"
                                                : "overridden in " + weeks.joined(separator: ", "))
            if let soonest = bounded.compactMap(\.validTo).min(), soonest > Date() {
                parts.append("expires " + DateFormatting.weekdayShort.string(from: soonest))
            }
        }
        if stack.kind.supportsGlob, stack.pattern.contains("*") { parts.append("wildcard") }
        parts.append(stack.kind == .urlPath ? "a path beats its host" : "most specific wins")
        return parts.joined(separator: " · ")
    }

    private func makePermanentPreview(_ stack: RuleStack?) -> String {
        guard let stack else { return "" }
        let target = projectName(for: stack.rules[0].projectID) ?? "the customer"
        return "Removes the \(stack.bounded.count) week-bounded rules for \(stack.pattern) (\(stackDescription(stack))) and writes one permanent rule → \(target). Past weeks re-attribute to it as well."
    }

    private func makePermanent(_ stack: RuleStack, customer: Customer) {
        let lead = stack.rules[0]
        do {
            for r in stack.bounded { try state.database.deleteRule(id: r.id) }
            try state.database.upsertReplacingWindow(Rule(
                id: UUID().uuidString, customerID: customer.id, projectID: lead.projectID,
                kind: stack.kind, pattern: stack.pattern, priority: 100, createdAt: Date()))
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private func projectName(for id: String?) -> String? {
        guard let id else { return nil }
        return customerProjects.first { $0.id == id }?.name
    }

    /// Short tag for a time-bounded (temporary) rule, else nil for permanent.
    private func ruleScopeLabel(_ rule: Rule) -> String? {
        guard rule.isTemporary, let to = rule.validTo else { return rule.isTemporary ? "temporary" : nil }
        let span = (rule.validFrom.map { to.timeIntervalSince($0) }) ?? 0
        if span > 0, span <= 36 * 3600 { return "today" }
        if span > 0, span <= 8 * 86400 { return "this week" }
        return "until " + to.formatted(.dateTime.day().month())
    }

    private func reload() {
        do {
            customers = try state.database.allCustomers()
            if let selectedCustomerID, !customers.contains(where: { $0.id == selectedCustomerID }) {
                self.selectedCustomerID = nil
            }
            allRules = try state.database.allRules()
            if let id = selectedCustomerID {
                rules = try state.database.rules(forCustomer: id)
                customerProjects = try state.database.projects(forCustomer: id)
            } else {
                rules = []
                customerProjects = []
            }
            if selectedCustomerID == nil, let first = customers.first {
                selectedCustomerID = first.id
                rules = try state.database.rules(forCustomer: first.id)
                customerProjects = try state.database.projects(forCustomer: first.id)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func addCustomer() {
        let name = newCustomerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let palette = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6"]
        let color = palette[customers.count % palette.count]
        let c = Customer(id: UUID().uuidString, name: name, color: color, createdAt: Date())
        do {
            try state.database.upsert(c)
            newCustomerName = ""
            selectedCustomerID = c.id
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(_ customer: Customer) {
        do {
            try state.database.deleteCustomer(id: customer.id)
            if selectedCustomerID == customer.id { selectedCustomerID = nil }
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(_ rule: Rule) {
        do {
            try state.database.deleteRule(id: rule.id)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func addProject(under customer: Customer) {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try state.database.createLocalProject(customerID: customer.id, name: name)
            newProjectName = ""
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(_ project: Project) {
        do {
            try state.database.deleteProject(id: project.id)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// One customer in the sidebar list. Reveals a delete button on hover for
/// local customers (Command Center customers are read-only). The context menu
/// remains as a secondary path; both route through a confirmation dialog.
private struct CustomerSidebarRow: View {
    let customer: Customer
    let onRequestDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: customer.displayColor) ?? .blue)
                .frame(width: 10, height: 10)
            Text(customer.name)
            Spacer(minLength: 0)
            if !customer.isExternal, hover {
                Button(role: .destructive, action: onRequestDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Delete customer")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// New rule, or an existing one edited in place (same id, same window).
/// Rules carry no visible priority: every rule is written at 100 and the
/// matcher's specificity order decides, which the row text explains.
private struct AddRuleSheet: View {
    let customerID: String
    let availableProjects: [Project]
    var existing: Rule? = nil
    let database: AppDatabase
    let onSave: (Rule) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Rule.Kind = .gitRepoSlug
    @State private var pattern: String = ""
    @State private var projectID: String = ""
    @State private var saveError: String?
    /// What the pattern matches in the last 90 days, refreshed as you type.
    @State private var matchSummary: String?
    private static let matchWindowDays = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New rule" : "Edit rule")
                .font(.title2.bold())

            Picker("Kind", selection: $kind) {
                ForEach(Rule.Kind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.menu)

            TextField("Pattern", text: $pattern, prompt: Text(kind.placeholder))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let matchSummary {
                Label(matchSummary, systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ruleMatchSummary")
            }

            if !availableProjects.isEmpty {
                Picker("Project", selection: $projectID) {
                    Text("(none — customer level)").tag("")
                    ForEach(availableProjects) { p in Text(p.name).tag(p.id) }
                }
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let r = Rule(
                        id: existing?.id ?? UUID().uuidString,
                        customerID: customerID,
                        projectID: projectID.isEmpty ? nil : projectID,
                        kind: kind,
                        pattern: trimmed,
                        priority: existing?.priority ?? 100,
                        createdAt: existing?.createdAt ?? Date(),
                        validFrom: existing?.validFrom,
                        validTo: existing?.validTo
                    )
                    do {
                        try onSave(r)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let existing {
                kind = existing.kind
                pattern = existing.pattern
                projectID = existing.projectID ?? ""
            }
        }
        .task(id: "\(kind.rawValue):\(pattern)") { await refreshMatchSummary() }
    }

    /// Debounced so a keystroke burst runs one query; the read happens off
    /// the main thread because it groups every sample of the window.
    private func refreshMatchSummary() async {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { matchSummary = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let db = database, kind = kind
        let since = Calendar.current.date(byAdding: .day, value: -Self.matchWindowDays, to: Date()) ?? Date()
        let interval = AppSettings.sampleIntervalSeconds
        let result = try? await Task.detached(priority: .userInitiated) {
            try db.ruleMatchCount(kind: kind, pattern: trimmed, since: since, sampleIntervalSeconds: interval)
        }.value
        guard !Task.isCancelled else { return }
        matchSummary = result.map(Self.describe) ?? "Couldn't count matches"
    }

    private static func describe(_ r: AppDatabase.RuleMatchCount) -> String {
        if r.isEmpty { return "No matches in the last \(matchWindowDays) days" }
        var parts: [String] = []
        if r.sampleSeconds > 0 {
            let h = r.sampleSeconds / 3600
            parts.append(h < 1 ? "\(Int((r.sampleSeconds / 60).rounded())) min of activity" : String(format: "%.1f h of activity", h))
        }
        if r.calls > 0 { parts.append("\(r.calls) call\(r.calls == 1 ? "" : "s")") }
        return "Matches " + parts.joined(separator: " · ") + " in the last \(matchWindowDays) days"
    }

    private var helpText: String {
        switch kind {
        case .gitRepoSlug:
            return "Matches the owner/name part of the git remote. Use * as a wildcard, e.g. `forefront/*`."
        case .gitRemoteHost:
            return "Matches the host of the git remote URL. Wildcards supported, e.g. `*.github.com`."
        case .urlHost:
            return "Matches the host of the active Chrome tab URL. Wildcards supported, e.g. `*.acme.com`."
        case .urlPath:
            return "Matches the full Chrome tab URL after the scheme is stripped. Wildcards supported, e.g. `github.com/forefront/foo*` to attribute a single repo."
        case .windowTitle:
            return "Substring (case-insensitive) found in the frontmost window title."
        case .appBundleID:
            return "App bundle identifier of the frontmost app. Wildcards supported."
        case .slackChannel:
            return "Slack channel name (no #), e.g. `nfc-internal`. Attributes both foreground time in that channel and huddles started there. Wildcards supported, e.g. `nfc-*`."
        case .participant:
            return "The other person in a 1:1 Teams, Zoom or Slack call, as the Calls tab shows them. Wildcards supported, e.g. `Anna *`."
        }
    }
}

/// Consistent marker for time that hasn't been attributed to a customer yet.
/// Pairs an icon with the label so the state isn't carried by color alone
/// (orange text is invisible to many colorblind users). Used in Review,
/// Calls, and anywhere a row can be unattributed.
struct UnattributedTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "questionmark.circle")
                .font(.caption2)
            Text("Unattributed")
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unattributed")
    }
}

/// Small "CC" capsule shown next to customers and projects synced from
/// Command Center. Used in CustomersView, ReviewView, and anywhere else the
/// user picks an attribution target.
struct CommandCenterBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "building.2")
                .font(.caption2)
            Text("CC")
                .font(.caption2.bold())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule().fill(Color.secondary.opacity(0.12))
        )
    }
}
