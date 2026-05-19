import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var state: AppState
    @State private var scope: DateScope = .lastDays(7)
    @State private var aggregates: [AppDatabase.SignalAggregate] = []
    @State private var matcher: RuleMatcher = .make(customers: [], projects: [], rules: [])
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var assignTarget: AppDatabase.SignalAggregate?
    @State private var loadError: String?
    @State private var suggestions: [String: AttributionSuggester.Suggestion] = [:]
    @State private var isSuggesting: Bool = false
    @State private var suggestionError: String?
    @State private var expandedHosts: Set<String> = []
    @State private var hostPathDetails: [String: [AppDatabase.SignalAggregate]] = [:]
    @State private var hidden: [HiddenSignal] = []
    @State private var hiddenExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if aggregates.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(title: "Git repos", kind: .gitRepoSlug)
                        section(title: "Meeting domains", kind: .meetingDomain)
                        section(title: "Browser hosts", kind: .urlHost)
                        section(title: "Apps", kind: .appBundleID)
                        hiddenSection
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: scope) { _, _ in
            hostPathDetails.removeAll()
            reload()
        }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .sheet(item: $assignTarget) { target in
            AssignSheet(
                signal: target,
                customers: customers,
                projects: projects,
                onCreateCustomer: { name in try createCustomer(name: name) },
                onCreateProject: { customerID, name in try createProject(customerID: customerID, name: name) },
                onSave: { customerID, projectID in
                    saveAssignment(for: target, customerID: customerID, projectID: projectID)
                }
            )
        }
        .alert("Database error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: { Text(loadError ?? "") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Where your time is going").font(.title3.bold())
                Spacer()
                Button {
                    Task { await runSuggest() }
                } label: {
                    if isSuggesting {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.55)
                            Text("Asking Claude…")
                        }
                    } else {
                        Label("Suggest with AI", systemImage: "sparkles")
                    }
                }
                .disabled(isSuggesting || unassignedSignals.isEmpty)
                rangePicker
            }
            if scope.isDay {
                dayControls
            }
            if let err = suggestionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var rangePicker: some View {
        Picker("", selection: rangeModeBinding) {
            Text("7 days").tag(7)
            Text("14 days").tag(14)
            Text("30 days").tag(30)
            Text("Day").tag(-1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
    }

    @ViewBuilder
    private var dayControls: some View {
        HStack(spacing: 8) {
            Button {
                if case .day(let d) = scope,
                   let prev = Calendar.current.date(byAdding: .day, value: -1, to: d) {
                    scope = .day(prev)
                }
            } label: { Image(systemName: "chevron.left") }

            Text(dayLabel)
                .font(.body.bold())
                .frame(minWidth: 180, alignment: .leading)

            Button {
                if case .day(let d) = scope,
                   let next = Calendar.current.date(byAdding: .day, value: 1, to: d) {
                    scope = .day(next)
                }
            } label: { Image(systemName: "chevron.right") }
            .disabled(isCurrentDayToday)

            Button("Today") {
                scope = .day(Calendar.current.startOfDay(for: Date()))
            }
            .disabled(isCurrentDayToday)
            Spacer()
        }
    }

    private var rangeModeBinding: Binding<Int> {
        Binding(
            get: {
                switch scope {
                case .lastDays(let n): return n
                case .day: return -1
                }
            },
            set: { newValue in
                if newValue == -1 {
                    if case .day = scope { return }
                    scope = .day(Calendar.current.startOfDay(for: Date()))
                } else {
                    scope = .lastDays(newValue)
                }
            }
        )
    }

    private var dayLabel: String {
        guard case .day(let d) = scope else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    private var isCurrentDayToday: Bool {
        guard case .day(let d) = scope else { return false }
        return Calendar.current.isDateInToday(d)
    }

    private var unassignedSignals: [AppDatabase.SignalAggregate] {
        visibleAggregates.filter {
            matcher.attribute(kind: ruleKind($0.kind), value: $0.value).customer == nil
        }
    }

    private var hiddenApps: Set<String> {
        Set(hidden.filter { $0.kind == .appBundleID }.map { $0.value })
    }

    private var hiddenHosts: Set<String> {
        Set(hidden.filter { $0.kind == .urlHost }.map { $0.value })
    }

    private func isHidden(_ item: AppDatabase.SignalAggregate) -> Bool {
        switch item.kind {
        case .appBundleID: return hiddenApps.contains(item.value)
        case .urlHost:     return hiddenHosts.contains(item.value)
        default:           return false
        }
    }

    private var visibleAggregates: [AppDatabase.SignalAggregate] {
        aggregates.filter { !isHidden($0) }
    }

    private var hiddenAggregates: [AppDatabase.SignalAggregate] {
        aggregates.filter { isHidden($0) }
    }

    private func canHide(_ item: AppDatabase.SignalAggregate) -> Bool {
        item.kind == .appBundleID || item.kind == .urlHost
    }

    private func hiddenSignalKind(for item: AppDatabase.SignalAggregate) -> HiddenSignal.Kind? {
        switch item.kind {
        case .appBundleID: return .appBundleID
        case .urlHost:     return .urlHost
        default:           return nil
        }
    }

    private func hide(_ item: AppDatabase.SignalAggregate) {
        guard let kind = hiddenSignalKind(for: item) else { return }
        do {
            try state.database.hideSignal(kind: kind, value: item.value)
            suggestions.removeValue(forKey: item.id)
            expandedHosts.remove(item.value)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func unhide(_ item: AppDatabase.SignalAggregate) {
        guard let kind = hiddenSignalKind(for: item) else { return }
        if let record = hidden.first(where: { $0.kind == kind && $0.value == item.value }) {
            do {
                try state.database.unhide(id: record.id)
                reload()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No activity recorded yet in this range.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func section(title: String, kind: AppDatabase.SignalAggregate.Kind) -> some View {
        let items = visibleAggregates.filter { $0.kind == kind }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                ForEach(items) { item in
                    hostRow(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private var hiddenSection: some View {
        let items = hiddenAggregates
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DisclosureGroup(isExpanded: $hiddenExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in
                            row(for: item, isExpandable: false, isHiddenRow: true)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                        Text("Hidden")
                            .font(.headline)
                        Text("(\(items.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Hidden apps and browser hosts are excluded from AI suggestions and from the Timeline (unless you enable “Show hidden”).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func hostRow(for item: AppDatabase.SignalAggregate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row(for: item, isExpandable: item.kind == .urlHost)
            if item.kind == .urlHost, expandedHosts.contains(item.value) {
                pathDetailRows(forHost: item.value)
                    .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder
    private func pathDetailRows(forHost host: String) -> some View {
        if let details = hostPathDetails[host] {
            if details.isEmpty {
                Text("No path detail available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(details) { detail in
                        row(for: detail, isExpandable: false, indented: true)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text("Loading paths…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func row(for item: AppDatabase.SignalAggregate,
                     isExpandable: Bool,
                     indented: Bool = false,
                     isHiddenRow: Bool = false) -> some View {
        let attribution = matcher.attribute(kind: ruleKind(item.kind), value: item.value)
        HStack(spacing: 12) {
            if isExpandable {
                Button {
                    toggleExpansion(host: item.value)
                } label: {
                    Image(systemName: expandedHosts.contains(item.value) ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else if indented {
                Spacer().frame(width: 12)
            }
            Image(systemName: icon(for: item.kind))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayValue(for: item, indented: indented))
                    .font((indented ? Font.caption : Font.body).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if attribution.customer != nil {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: attribution.project?.color ?? attribution.customer?.color) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(attributionLabel(attribution))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !isHiddenRow, !indented || item.kind == .urlPath {
                    Text("Unassigned")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(formatHours(item.totalSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            if !isHiddenRow, let suggestion = suggestions[item.id] {
                suggestionBadge(suggestion, for: item)
            }
            if isHiddenRow {
                Button {
                    unhide(item)
                } label: {
                    Label("Unhide", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                if canHide(item) {
                    Button {
                        hide(item)
                    } label: {
                        Image(systemName: "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Hide this \(item.kind == .appBundleID ? "app" : "host") from Discover and Timeline")
                }
                Button(attribution.customer == nil ? "Assign…" : "Change…") {
                    assignTarget = item
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, indented ? 4 : 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor).opacity(indented ? 0.5 : 1.0)))
    }

    private func displayValue(for item: AppDatabase.SignalAggregate, indented: Bool) -> String {
        if indented, item.kind == .urlPath, let slash = item.value.firstIndex(of: "/") {
            // Strip host: show just the path portion under the host header.
            return String(item.value[slash...])
        }
        return item.value
    }

    private func toggleExpansion(host: String) {
        if expandedHosts.contains(host) {
            expandedHosts.remove(host)
            return
        }
        expandedHosts.insert(host)
        if hostPathDetails[host] != nil { return }
        loadPathDetails(forHost: host)
    }

    private func loadPathDetails(forHost host: String) {
        do {
            let details = try state.database.urlPathAggregates(
                forHost: host,
                in: scope.interval,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds
            )
            hostPathDetails[host] = details
        } catch {
            hostPathDetails[host] = []
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func suggestionBadge(_ s: AttributionSuggester.Suggestion,
                                 for item: AppDatabase.SignalAggregate) -> some View {
        let confidenceColor: Color = s.confidence >= 0.9 ? .green
            : s.confidence >= 0.6 ? .blue
            : .orange
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(confidenceColor)
            VStack(alignment: .leading, spacing: 1) {
                let projSuffix = s.projectName.map { " · \($0)\(s.projectIsNew ? " ⊕" : "")" } ?? ""
                Text("\(s.customerName)\(s.isNewCustomer ? " ⊕" : "")\(projSuffix)")
                    .font(.caption)
                Text(s.reasoning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(String(format: "%.0f%%", s.confidence * 100))
                .font(.caption2.monospaced())
                .foregroundStyle(confidenceColor)
            Button("Accept") {
                acceptSuggestion(s, for: item)
            }
            .controlSize(.small)
            Button {
                suggestions.removeValue(forKey: item.id)
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(confidenceColor.opacity(0.08)))
    }

    private func runSuggest() async {
        suggestionError = nil
        suggestions = [:]
        isSuggesting = true
        defer { isSuggesting = false }

        let inputs = unassignedSignals.map {
            AttributionSuggester.InputSignal(
                id: $0.id,
                kind: $0.kind,
                value: $0.value,
                totalSeconds: $0.totalSeconds
            )
        }
        guard !inputs.isEmpty else { return }

        let suggester = AttributionSuggester(api: state.claudeAPI)
        do {
            let rules = try state.database.allRules()
            let results = try await suggester.suggest(
                signals: inputs,
                customers: customers,
                projects: projects,
                rules: rules,
                model: AppSettings.aiModel
            )
            suggestions = Dictionary(uniqueKeysWithValues: results.map { ($0.signalID, $0) })
        } catch {
            suggestionError = "\(error)"
        }
    }

    private func acceptSuggestion(_ s: AttributionSuggester.Suggestion,
                                  for item: AppDatabase.SignalAggregate) {
        do {
            // Find or create the customer.
            let customer: Customer
            if let existing = customers.first(where: { $0.name.localizedCaseInsensitiveCompare(s.customerName) == .orderedSame }) {
                customer = existing
            } else {
                customer = try createCustomer(name: s.customerName)
            }

            // Find or create the project, if specified and supported by this signal kind.
            var projectID: String? = nil
            if let pname = s.projectName, item.kind == .gitRepoSlug {
                if let existing = projects.first(where: {
                    $0.customerID == customer.id
                        && $0.name.localizedCaseInsensitiveCompare(pname) == .orderedSame
                }) {
                    projectID = existing.id
                } else {
                    let p = try createProject(customerID: customer.id, name: pname)
                    projectID = p.id
                }
            }

            // Use the model's suggested pattern if it looks sane; else fall back to the raw value.
            let pattern = s.rulePattern.isEmpty ? item.value : s.rulePattern

            saveAssignment(for: AppDatabase.SignalAggregate(
                kind: item.kind, value: pattern, totalSeconds: item.totalSeconds
            ), customerID: customer.id, projectID: projectID)

            suggestions.removeValue(forKey: item.id)
        } catch {
            suggestionError = error.localizedDescription
        }
    }

    private func attributionLabel(_ a: AttributionResult) -> String {
        guard let c = a.customer else { return "Unassigned" }
        if let p = a.project { return "\(c.name) · \(p.name)" }
        return c.name
    }

    private func icon(for kind: AppDatabase.SignalAggregate.Kind) -> String {
        switch kind {
        case .gitRepoSlug: return "chevron.left.forwardslash.chevron.right"
        case .urlHost: return "globe"
        case .urlPath: return "link"
        case .appBundleID: return "app"
        case .meetingDomain: return "envelope"
        }
    }

    private func ruleKind(_ k: AppDatabase.SignalAggregate.Kind) -> Rule.Kind {
        switch k {
        case .gitRepoSlug: return .gitRepoSlug
        case .urlHost: return .urlHost
        case .urlPath: return .urlPath
        case .appBundleID: return .appBundleID
        case .meetingDomain: return .emailDomain
        }
    }

    private func formatHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        if hours < 1 { return String(format: "%.0f min", seconds / 60.0) }
        return String(format: "%.1f h", hours)
    }

    private func reload() {
        do {
            let interval = scope.interval
            var baseAggs = try state.database.signalAggregates(
                in: interval,
                sampleIntervalSeconds: AppSettings.sampleIntervalSeconds
            )
            // Fold session activeSeconds into the matching git-repo-slug aggregates.
            let idleThreshold = TimeInterval(AppSettings.claudeIdleThresholdMinutes * 60)
            let sessionRepos = try state.database.sessionRepoAggregates(
                in: interval,
                idleThresholdSeconds: idleThreshold
            )
            if !sessionRepos.isEmpty {
                var bySlug: [String: Double] = [:]
                var others: [AppDatabase.SignalAggregate] = []
                for agg in baseAggs {
                    if agg.kind == .gitRepoSlug {
                        bySlug[agg.value, default: 0] += agg.totalSeconds
                    } else {
                        others.append(agg)
                    }
                }
                for sessionAgg in sessionRepos {
                    bySlug[sessionAgg.value, default: 0] += sessionAgg.totalSeconds
                }
                let merged = bySlug.map { AppDatabase.SignalAggregate(kind: .gitRepoSlug, value: $0.key, totalSeconds: $0.value) }
                baseAggs = others + merged
            }
            // Meeting domain aggregates over the same range, blended in and sorted by time.
            let meetingAggs = try state.database.meetingDomainAggregates(in: interval)
            baseAggs.append(contentsOf: meetingAggs)
            baseAggs.sort { $0.totalSeconds > $1.totalSeconds }
            self.aggregates = baseAggs
            self.customers = try state.database.allCustomers()
            self.projects = try state.database.allProjects()
            let rules = try state.database.allRules()
            self.matcher = RuleMatcher.make(customers: customers, projects: projects, rules: rules)
            self.hidden = try state.database.allHiddenSignals()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func createCustomer(name: String) throws -> Customer {
        let palette = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6"]
        let color = palette[customers.count % palette.count]
        let c = Customer(id: UUID().uuidString, name: name, color: color, createdAt: Date())
        try state.database.upsert(c)
        return c
    }

    private func createProject(customerID: String, name: String) throws -> Project {
        let p = Project(id: UUID().uuidString, customerID: customerID, name: name, color: nil, createdAt: Date())
        try state.database.upsert(p)
        return p
    }

    private func saveAssignment(for signal: AppDatabase.SignalAggregate, customerID: String, projectID: String?) {
        let kind = ruleKind(signal.kind)
        // urlPath rules use the prefix value plus `*` so deeper paths under the same
        // owner/repo (e.g. `github.com/forefront/foo/issues/123`) also match.
        let pattern: String
        if signal.kind == .urlPath, !signal.value.contains("*") {
            pattern = signal.value + "*"
        } else {
            pattern = signal.value
        }
        do {
            // Delete any existing rules with same (kind, pattern) to keep the assignment unique.
            let existing = try state.database.allRules()
                .filter { $0.kind == kind && $0.pattern == pattern }
            for rule in existing {
                try state.database.deleteRule(id: rule.id)
            }
            let r = Rule(
                id: UUID().uuidString,
                customerID: customerID,
                projectID: projectID,
                kind: kind,
                pattern: pattern,
                priority: 100,
                createdAt: Date()
            )
            try state.database.upsert(r)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct AssignSheet: View {
    let signal: AppDatabase.SignalAggregate
    let customers: [Customer]
    let projects: [Project]
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    let onSave: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCustomerID: String?
    @State private var selectedProjectID: String?
    @State private var newCustomerName: String = ""
    @State private var newProjectName: String = ""
    @State private var creatingCustomer = false
    @State private var creatingProject = false
    @State private var localCustomers: [Customer] = []
    @State private var localProjects: [Project] = []
    @State private var error: String?

    private var canPickProject: Bool { signal.kind == .gitRepoSlug }
    private var hideProjectExplanation: Bool { signal.kind == .meetingDomain }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assign signal").font(.title2.bold())
                Text(signal.value)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            customerPicker

            if canPickProject, selectedCustomerID != nil {
                projectPicker
            } else if !canPickProject {
                Text("Project assignment is only available for Git repos. \(kindLabel) maps directly to a customer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCustomerID == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            localCustomers = customers
            localProjects = projects
        }
    }

    private var kindLabel: String {
        switch signal.kind {
        case .gitRepoSlug: return "Git repo"
        case .urlHost: return "Browser host"
        case .urlPath: return "Browser URL"
        case .appBundleID: return "App"
        case .meetingDomain: return "Meeting attendee domain"
        }
    }

    @ViewBuilder
    private var customerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Customer").font(.subheadline.bold())
            if creatingCustomer {
                HStack {
                    TextField("Customer name", text: $newCustomerName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { confirmCreateCustomer() }
                    Button("Add") { confirmCreateCustomer() }
                        .disabled(newCustomerName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { creatingCustomer = false; newCustomerName = "" }
                }
            } else {
                HStack {
                    Picker("", selection: Binding(
                        get: { selectedCustomerID ?? "" },
                        set: { newValue in
                            selectedCustomerID = newValue.isEmpty ? nil : newValue
                            selectedProjectID = nil
                        }
                    )) {
                        Text("Choose…").tag("")
                        ForEach(localCustomers) { c in
                            Text(c.name).tag(c.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button("+ New") { creatingCustomer = true }
                }
            }
        }
    }

    @ViewBuilder
    private var projectPicker: some View {
        let availableProjects = localProjects.filter { $0.customerID == selectedCustomerID }
        VStack(alignment: .leading, spacing: 6) {
            Text("Project").font(.subheadline.bold())
            if creatingProject {
                HStack {
                    TextField("Project name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { confirmCreateProject() }
                    Button("Add") { confirmCreateProject() }
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { creatingProject = false; newProjectName = "" }
                }
            } else {
                HStack {
                    Picker("", selection: Binding(
                        get: { selectedProjectID ?? "" },
                        set: { selectedProjectID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("(no project)").tag("")
                        ForEach(availableProjects) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button("+ New") { creatingProject = true }
                        .disabled(selectedCustomerID == nil)
                }
            }
        }
    }

    private func confirmCreateCustomer() {
        let name = newCustomerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let c = try onCreateCustomer(name)
            localCustomers.append(c)
            localCustomers.sort { $0.name < $1.name }
            selectedCustomerID = c.id
            selectedProjectID = nil
            creatingCustomer = false
            newCustomerName = ""
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func confirmCreateProject() {
        guard let customerID = selectedCustomerID else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let p = try onCreateProject(customerID, name)
            localProjects.append(p)
            localProjects.sort { $0.name < $1.name }
            selectedProjectID = p.id
            creatingProject = false
            newProjectName = ""
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func save() {
        guard let customerID = selectedCustomerID else { return }
        onSave(customerID, canPickProject ? selectedProjectID : nil)
        dismiss()
    }
}
