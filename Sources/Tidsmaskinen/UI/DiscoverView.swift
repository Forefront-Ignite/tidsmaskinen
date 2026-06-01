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
    @State private var meetingSeries: [AppDatabase.MeetingSeriesAggregate] = []
    @State private var oneOffMeetings: [CalendarEvent] = []
    @State private var ignoredMeetings: [AppDatabase.IgnoredMeetingAggregate] = []
    @State private var ignoredExpanded: Bool = false
    @State private var seriesAttributionsByID: [String: MeetingSeriesAttribution] = [:]
    @State private var seriesAssignTarget: AppDatabase.MeetingSeriesAggregate?
    @State private var eventAssignTarget: CalendarEvent?

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
                        meetingsSection
                        section(title: "Browser hosts", kind: .urlHost)
                        section(title: "Apps", kind: .appBundleID)
                        ignoredMeetingsSection
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
            AssignmentSheet(
                title: "Attribute signal",
                subtitle: target.value,
                customers: customers,
                projects: projects,
                onCreateCustomer: { name in try state.database.createLocalCustomer(name: name) },
                onCreateProject: { customerID, name in try state.database.createLocalProject(customerID: customerID, name: name) },
                onSave: { customerID, projectID in
                    saveAssignment(for: target, customerID: customerID, projectID: projectID)
                }
            )
        }
        .sheet(item: $seriesAssignTarget) { target in
            AssignmentSheet(
                title: "Attribute meeting series",
                subtitle: target.sampleSubject,
                customers: customers,
                projects: projects,
                onCreateCustomer: { name in try state.database.createLocalCustomer(name: name) },
                onCreateProject: { customerID, name in try state.database.createLocalProject(customerID: customerID, name: name) },
                onSave: { customerID, projectID in
                    saveSeriesAttribution(seriesID: target.seriesMasterID, customerID: customerID, projectID: projectID)
                }
            )
        }
        .sheet(item: $eventAssignTarget) { target in
            AssignmentSheet(
                title: "Attribute meeting",
                subtitle: target.subject.isEmpty ? "(no subject)" : target.subject,
                customers: customers,
                projects: projects,
                onCreateCustomer: { name in try state.database.createLocalCustomer(name: name) },
                onCreateProject: { customerID, name in try state.database.createLocalProject(customerID: customerID, name: name) },
                onSave: { customerID, projectID in
                    saveEventAttribution(eventID: target.id, customerID: customerID, projectID: projectID)
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
            HStack(alignment: .top) {
                Text("Where your time is going — attribute apps, sites, repos and meetings to a customer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440, alignment: .leading)
                Spacer()
                RangeScopePicker(scope: $scope)
            }
            if scope.isDay {
                ScopeDayNavigator(scope: $scope)
            }
            filterBar
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $unassignedOnly) {
                Text("Unattributed only").font(.caption)
            }
            .toggleStyle(.checkbox)

            SearchableEntityPicker(
                items: customers.map {
                    .init(id: $0.id, label: $0.name, isExternal: $0.isExternal)
                },
                selectedID: Binding(
                    get: { customerFilterID ?? "" },
                    set: { customerFilterID = $0.isEmpty ? nil : $0 }
                ),
                placeholder: "All customers",
                allowsClear: true,
                clearLabel: "All customers",
                canSync: AppSettings.commandCenterEnabled && state.commandCenterHasToken,
                isSyncing: state.commandCenterIsSyncing,
                lastSyncedAt: state.commandCenterLastSyncAt,
                onSync: { Task { await state.refreshCommandCenter() } }
            )
            .frame(maxWidth: 220)

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
        ContentUnavailableView(
            "No activity recorded yet in this range",
            systemImage: "clock.arrow.circlepath",
            description: Text("As you work, apps, browser hosts, git repos and meetings show up here to attribute.")
        )
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
                ProgressView().controlSize(.small)
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
                            .fill(Color(hex: attribution.project?.displayColor ?? attribution.customer?.displayColor) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(attributionLabel(attribution))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !isHiddenRow,
                          !indented || item.kind == .urlPath,
                          !(item.kind == .urlHost && fullyCoveredHosts.contains(item.value)) {
                    UnattributedTag()
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
                Button(attribution.customer == nil ? "Attribute…" : "Change…") {
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
        guard let c = a.customer else { return "Unattributed" }
        if let p = a.project { return "\(c.name) · \(p.name)" }
        return c.name
    }

    private func icon(for kind: AppDatabase.SignalAggregate.Kind) -> String {
        switch kind {
        case .gitRepoSlug: return "chevron.left.forwardslash.chevron.right"
        case .urlHost: return "globe"
        case .urlPath: return "link"
        case .appBundleID: return "app"
        }
    }

    private func ruleKind(_ k: AppDatabase.SignalAggregate.Kind) -> Rule.Kind {
        switch k {
        case .gitRepoSlug: return .gitRepoSlug
        case .urlHost: return .urlHost
        case .urlPath: return .urlPath
        case .appBundleID: return .appBundleID
        }
    }

    private func formatHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        if hours < 1 { return String(format: "%.0f min", seconds / 60.0) }
        return String(format: "%.1f h", hours)
    }

    // MARK: - Meetings

    /// Filtered view of recurring series + one-off meetings, honouring the
    /// "Unassigned only" toggle and customer filter so the list narrows like
    /// the other Discover sections.
    private var visibleMeetingSeries: [AppDatabase.MeetingSeriesAggregate] {
        meetingSeries.filter { series in
            let attr = seriesAttributionsByID[series.seriesMasterID]
            if attr?.isIgnored == true { return false }
            let attrCustomerID = attr?.customerID
            if unassignedOnly, attrCustomerID != nil { return false }
            if let cid = customerFilterID {
                return attrCustomerID == cid
            }
            return true
        }
    }

    private var visibleOneOffMeetings: [CalendarEvent] {
        oneOffMeetings.filter { event in
            if unassignedOnly, event.customerID != nil { return false }
            if let cid = customerFilterID {
                return event.customerID == cid
            }
            return true
        }
    }

    @ViewBuilder
    private var meetingsSection: some View {
        let series = visibleMeetingSeries
        let oneOffs = visibleOneOffMeetings
        if !series.isEmpty || !oneOffs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Meetings").font(.headline)
                if !series.isEmpty {
                    Text("Recurring series")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(series) { row in
                        seriesRow(row)
                    }
                }
                if !oneOffs.isEmpty {
                    Text("One-off meetings")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(oneOffs) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func seriesRow(_ row: AppDatabase.MeetingSeriesAggregate) -> some View {
        let attr = seriesAttributionsByID[row.seriesMasterID]
        let attribution = attr.flatMap { resolveAttribution(customerID: $0.customerID, projectID: $0.projectID) }
        HStack(spacing: 12) {
            Image(systemName: "repeat")
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.sampleSubject)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(row.occurrenceCount) occurrences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let attribution, let customer = attribution.customer {
                        Text("·").foregroundStyle(.tertiary)
                        Circle()
                            .fill(Color(hex: attribution.project?.displayColor ?? customer.displayColor) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(attributionLabel(attribution))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("·").foregroundStyle(.tertiary)
                        UnattributedTag()
                    }
                }
            }
            Spacer()
            Text(formatHours(row.totalSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            Button {
                ignoreSeries(row.seriesMasterID)
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Ignore series — every occurrence is excluded from Timeline and the weekly report.")
            Button(attr?.customerID == nil ? "Attribute…" : "Change…") {
                seriesAssignTarget = row
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEvent) -> some View {
        let attribution = resolveAttribution(customerID: event.customerID, projectID: event.projectID)
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.subject.isEmpty ? "(no subject)" : event.subject)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(eventTimeLabel(event))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let customer = attribution.customer {
                        Text("·").foregroundStyle(.tertiary)
                        Circle()
                            .fill(Color(hex: attribution.project?.displayColor ?? customer.displayColor) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(attributionLabel(attribution))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("·").foregroundStyle(.tertiary)
                        UnattributedTag()
                    }
                }
            }
            Spacer()
            Text(formatHours(max(0, event.endAt.timeIntervalSince(event.startAt))))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            Button {
                ignoreEvent(event.id)
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Ignore this meeting — excluded from Timeline and the weekly report.")
            Button(event.customerID == nil ? "Attribute…" : "Change…") {
                eventAssignTarget = event
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private var ignoredMeetingsSection: some View {
        if !ignoredMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DisclosureGroup(isExpanded: $ignoredExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ignoredMeetings) { row in
                            ignoredMeetingRow(row)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                        Text("Ignored meetings")
                            .font(.headline)
                        Text("(\(ignoredMeetings.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Ignored meetings and series are excluded from Timeline and the weekly report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func ignoredMeetingRow(_ row: AppDatabase.IgnoredMeetingAggregate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.scope == .series ? "repeat" : "calendar")
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.scope == .series ? "Series" : "Single meeting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let count = row.occurrenceCount {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(count) occurrences in range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(formatHours(row.totalSeconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            Button {
                unignoreMeeting(row)
            } label: {
                Label("Un-ignore", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor).opacity(0.5)))
    }

    private func eventTimeLabel(_ event: CalendarEvent) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM HH:mm"
        return df.string(from: event.startAt)
    }

    private func resolveAttribution(customerID: String?, projectID: String?) -> AttributionResult {
        guard let cid = customerID, let customer = matcher.customersByID[cid] else {
            return .unattributed
        }
        let project = projectID.flatMap { matcher.projectsByID[$0] }
        return AttributionResult(customer: customer, project: project, matchingRule: nil)
    }

    private func saveSeriesAttribution(seriesID: String, customerID: String, projectID: String?) {
        do {
            try state.database.setMeetingSeriesAttribution(
                seriesID: seriesID,
                customerID: customerID,
                projectID: projectID,
                isIgnored: false
            )
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveEventAttribution(eventID: String, customerID: String, projectID: String?) {
        do {
            try state.database.setCalendarEventAttribution(eventID: eventID, customerID: customerID, projectID: projectID)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func ignoreSeries(_ seriesID: String) {
        do {
            try state.database.setMeetingSeriesAttribution(
                seriesID: seriesID,
                customerID: nil,
                projectID: nil,
                isIgnored: true
            )
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func ignoreEvent(_ eventID: String) {
        do {
            try state.database.setCalendarEventIgnored(eventID: eventID, isIgnored: true)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func unignoreMeeting(_ row: AppDatabase.IgnoredMeetingAggregate) {
        do {
            switch row.scope {
            case .event:
                try state.database.setCalendarEventIgnored(eventID: row.id, isIgnored: false)
            case .series:
                // Clear the entire row — falls back to "no series attribution".
                try state.database.setMeetingSeriesAttribution(
                    seriesID: row.id,
                    customerID: nil,
                    projectID: nil,
                    isIgnored: false
                )
            }
            reload()
        } catch {
            loadError = error.localizedDescription
        }
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
            baseAggs.sort { $0.totalSeconds > $1.totalSeconds }
            self.meetingSeries = try state.database.meetingSeriesAggregates(in: interval)
            self.oneOffMeetings = try state.database.oneOffMeetingAggregates(in: interval)
            self.ignoredMeetings = try state.database.ignoredMeetingAggregates(in: interval)
            self.aggregates = baseAggs
            self.customers = try state.database.allCustomers()
            self.projects = try state.database.allProjects()
            let rules = try state.database.allRules()
            let seriesAttrs = try state.database.allMeetingSeriesAttributions()
            self.seriesAttributionsByID = Dictionary(uniqueKeysWithValues: seriesAttrs.map { ($0.seriesMasterID, $0) })
            self.matcher = RuleMatcher.make(customers: customers,
                                            projects: projects,
                                            rules: rules,
                                            series: seriesAttrs)
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

