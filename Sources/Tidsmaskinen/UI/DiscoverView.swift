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
    @State private var expandedHosts: Set<String> = []
    @State private var hostPathDetails: [String: [AppDatabase.SignalAggregate]] = [:]
    @State private var hidden: [HiddenSignal] = []
    @State private var hiddenExpanded: Bool = false
    @State private var unassignedOnly: Bool = false
    @State private var customerFilterID: String? = nil

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
                rangePicker
            }
            if scope.isDay {
                dayControls
            }
            filterBar
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

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $unassignedOnly) {
                Text("Unassigned only").font(.caption)
            }
            .toggleStyle(.checkbox)

            Picker("", selection: Binding(
                get: { customerFilterID ?? "" },
                set: { customerFilterID = $0.isEmpty ? nil : $0 }
            )) {
                Text("All customers").tag("")
                Divider()
                ForEach(customers) { c in
                    Text(c.name).tag(c.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 200)

            if unassignedOnly || customerFilterID != nil {
                Button {
                    unassignedOnly = false
                    customerFilterID = nil
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    /// Customer IDs attributed to *any* loaded child path under each urlHost.
    private var hostChildCustomerIDs: [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for (host, details) in hostPathDetails {
            var set = Set<String>()
            for detail in details {
                if let cid = matcher.attribute(kind: .urlPath, value: detail.value).customer?.id {
                    set.insert(cid)
                }
            }
            map[host] = set
        }
        return map
    }

    /// urlHosts whose own attribution is empty AND every loaded child path is attributed.
    /// Used to hide the "Unassigned" tag and to skip the host under the "Unassigned only" filter.
    private var fullyCoveredHosts: Set<String> {
        var set = Set<String>()
        for agg in aggregates where agg.kind == .urlHost {
            guard matcher.attribute(kind: .urlHost, value: agg.value).customer == nil else { continue }
            guard let details = hostPathDetails[agg.value], !details.isEmpty else { continue }
            let allAssigned = details.allSatisfy {
                matcher.attribute(kind: .urlPath, value: $0.value).customer != nil
            }
            if allAssigned { set.insert(agg.value) }
        }
        return set
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
        let covered = fullyCoveredHosts
        let childIDs = hostChildCustomerIDs
        return aggregates.filter { agg in
            if isHidden(agg) { return false }
            let attr = matcher.attribute(kind: ruleKind(agg.kind), value: agg.value)

            if unassignedOnly {
                if agg.kind == .urlHost {
                    if attr.customer != nil { return false }       // host is assigned
                    if covered.contains(agg.value) { return false } // all children assigned
                } else {
                    if attr.customer != nil { return false }
                }
            }

            if let cid = customerFilterID {
                if attr.customer?.id == cid { return true }
                if agg.kind == .urlHost,
                   let children = childIDs[agg.value], children.contains(cid) {
                    return true
                }
                return false
            }
            return true
        }
    }

    /// True when path-detail rows should be limited to children matching the active filters.
    private var filtersAffectChildren: Bool {
        unassignedOnly || customerFilterID != nil
    }

    private func filteredPathDetails(_ details: [AppDatabase.SignalAggregate]) -> [AppDatabase.SignalAggregate] {
        guard filtersAffectChildren else { return details }
        return details.filter { detail in
            let attr = matcher.attribute(kind: .urlPath, value: detail.value)
            if unassignedOnly, attr.customer != nil { return false }
            if let cid = customerFilterID, attr.customer?.id != cid { return false }
            return true
        }
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
                Text("Hidden apps and browser hosts are excluded from the Timeline unless you enable “Show hidden”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func hostRow(for item: AppDatabase.SignalAggregate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row(for: item, isExpandable: item.kind == .urlHost)
            if item.kind == .urlHost, isHostExpanded(item.value) {
                pathDetailRows(forHost: item.value)
                    .padding(.leading, 28)
            }
        }
    }

    /// Hosts are forced open when a filter is active so the matching child paths are visible without manual expansion.
    private func isHostExpanded(_ host: String) -> Bool {
        if filtersAffectChildren { return true }
        return expandedHosts.contains(host)
    }

    @ViewBuilder
    private func pathDetailRows(forHost host: String) -> some View {
        if let details = hostPathDetails[host] {
            let shown = filteredPathDetails(details)
            if shown.isEmpty {
                Text(filtersAffectChildren ? "No paths match the active filter." : "No path detail available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { detail in
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
                } else if !isHiddenRow,
                          !indented || item.kind == .urlPath,
                          !(item.kind == .urlHost && fullyCoveredHosts.contains(item.value)) {
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
        // Make the entire row a hit target for the disclosure when expandable —
        // the small chevron is a precise tap. Inner Buttons (Assign…, hide,
        // chevron) consume their own taps so this only fires on row body.
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpandable {
                toggleExpansion(host: item.value)
            }
        }
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
            // Eager-load path detail for urlHosts whose own attribution is empty so we can:
            //   - hide the parent "Unassigned" tag when every child is assigned
            //   - honor customer/unassigned filters that look at child rows
            for agg in baseAggs where agg.kind == .urlHost {
                if hostPathDetails[agg.value] != nil { continue }
                if matcher.attribute(kind: .urlHost, value: agg.value).customer != nil { continue }
                if isHidden(agg) { continue }
                loadPathDetails(forHost: agg.value)
            }
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

            if selectedCustomerID != nil {
                projectPicker
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
        onSave(customerID, selectedProjectID)
        dismiss()
    }
}
