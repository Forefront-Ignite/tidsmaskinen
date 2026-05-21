import SwiftUI

/// Calls tab — lists mic-active intervals captured by MicMonitor. Each row is
/// one continuous mic-in-use session: when it started, how long, and which
/// VoIP-style apps were running so we can guess "this was a Teams call" /
/// "this was a Slack huddle". Attribution is per-row and writes only to the
/// MicSession record — it does NOT touch sample-level attribution, since the
/// underlying foreground samples were doing other work in parallel.
struct TeamsCallsView: View {
    @EnvironmentObject private var state: AppState
    @State private var scope: DateScope = .lastDays(7)
    @State private var sessions: [MicSession] = []
    @State private var customers: [Customer] = []
    @State private var projects: [Project] = []
    @State private var loadError: String?
    @State private var attributing: MicSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if sessions.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groupedByDay, id: \.0) { (day, items) in
                            Text(dayHeader(day))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                            ForEach(items) { row($0) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: scope) { _, _ in reload() }
        .onChange(of: state.sampleCount) { _, _ in reload() }
        .sheet(item: $attributing) { session in
            CallDetailSheet(
                session: session,
                customers: customers,
                projects: projects,
                database: state.database,
                onSave: { customerID, projectID in
                    save(session: session, customerID: customerID, projectID: projectID)
                },
                onClear: {
                    save(session: session, customerID: nil, projectID: nil)
                }
            )
        }
        .alert("Error", isPresented: errorBinding) {
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calls").font(.title3.bold())
                    Text("Microphone-active sessions, regardless of which app was frontmost. Tagged with whichever VoIP apps were running at the time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
            if scope.isDay {
                dayControls
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "mic.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No mic-active sessions captured in this range yet.")
                .foregroundStyle(.secondary)
            Text("New sessions will appear as soon as you have a call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ s: MicSession) -> some View {
        let customer = s.customerID.flatMap { id in customers.first(where: { $0.id == id }) }
        let project = s.projectID.flatMap { id in projects.first(where: { $0.id == id }) }

        Button {
            attributing = s
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: s))
                    .frame(width: 22)
                    .foregroundStyle(color(for: s))

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLine(for: s))
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(timeRange(s))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(durationLabel(s))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !appLabels(for: s).isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(appLabels(for: s).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if let c = customer {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: project?.color ?? c.color) ?? .blue)
                            .frame(width: 8, height: 8)
                        Text(attributionLabel(customer: c, project: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if s.endedAt != nil {
                    Text("Unattributed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Ongoing")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        }
        .buttonStyle(.plain)
    }

    private func icon(for s: MicSession) -> String {
        if s.endedAt == nil { return "mic.fill" }
        let apps = s.voipApps
        if apps.contains(where: { $0.hasPrefix("com.microsoft.teams") }) { return "phone.fill" }
        if apps.contains(where: { $0.contains("zoom") }) { return "video.fill" }
        if apps.contains(where: { $0.contains("slack") }) { return "bubble.left.and.bubble.right.fill" }
        if apps.contains(where: { $0.contains("webex") }) { return "video.fill" }
        if apps.contains(where: { $0.contains("discord") }) { return "gamecontroller.fill" }
        if apps.contains(where: { $0.contains("facetime") }) { return "phone.fill" }
        if apps.isEmpty { return "waveform" }
        return "phone.fill"
    }

    private func color(for s: MicSession) -> Color {
        if s.endedAt == nil { return .red }
        return s.voipApps.isEmpty ? .gray : .green
    }

    private func titleLine(for s: MicSession) -> String {
        if let p = s.participant, !p.isEmpty { return p }
        let labels = appLabels(for: s)
        if labels.count == 1 { return labels[0] }
        if !labels.isEmpty { return labels.joined(separator: " / ") }
        return "Microphone activity"
    }

    private func appLabels(for s: MicSession) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for bid in s.voipApps {
            if let label = MicMonitor.displayName(forBundleID: bid), !seen.contains(label) {
                seen.insert(label)
                out.append(label)
            }
        }
        return out
    }

    private func attributionLabel(customer: Customer, project: Project?) -> String {
        if let p = project { return "\(customer.name) · \(p.name)" }
        return customer.name
    }

    private func timeRange(_ s: MicSession) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let start = f.string(from: s.startedAt)
        let end = s.endedAt.map { f.string(from: $0) } ?? "…"
        return "\(start)–\(end)"
    }

    private func durationLabel(_ s: MicSession) -> String {
        let secs = s.durationSeconds ?? Date().timeIntervalSince(s.startedAt)
        let mins = Int((secs / 60).rounded())
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    private var groupedByDay: [(Date, [MicSession])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    private func dayHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }

    private func reload() {
        do {
            sessions = try state.database.micSessions(in: scope.interval)
            customers = try state.database.allCustomers()
            projects = try state.database.allProjects()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save(session: MicSession, customerID: String?, projectID: String?) {
        do {
            try state.database.setMicSessionAttribution(
                id: session.id,
                customerID: customerID,
                projectID: projectID
            )
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct CallDetailSheet: View {
    let session: MicSession
    let customers: [Customer]
    let projects: [Project]
    let database: AppDatabase
    let onSave: (String?, String?) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCustomerID: String = ""
    @State private var selectedProjectID: String = ""
    @State private var appBreakdown: [AppUsage] = []
    @State private var urlBreakdown: [URLUsage] = []
    @State private var loadError: String?

    // Local copies so newly-created customers/projects appear immediately
    // in the picker without having to dismiss and reopen the sheet. The
    // parent reloads from the DB after save.
    @State private var localCustomers: [Customer] = []
    @State private var localProjects: [Project] = []
    @State private var creatingCustomer = false
    @State private var creatingProject = false
    @State private var newCustomerName = ""
    @State private var newProjectName = ""

    struct AppUsage: Identifiable, Hashable {
        let id: String         // bundle ID
        let name: String
        let seconds: Double
    }

    struct URLUsage: Identifiable, Hashable {
        let id: String         // url prefix
        let seconds: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            attributionSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !appBreakdown.isEmpty { appsSection }
                    if !urlBreakdown.isEmpty { urlsSection }
                    if appBreakdown.isEmpty && urlBreakdown.isEmpty {
                        Text("No foreground activity captured during this call.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .onAppear {
            selectedCustomerID = session.customerID ?? ""
            selectedProjectID = session.projectID ?? ""
            localCustomers = customers
            localProjects = projects
            loadBreakdowns()
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: { Text(loadError ?? "") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.participant ?? "Microphone activity").font(.title2.bold())
            Text(headerDetailLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if !appLabels.isEmpty {
                Text("Running: \(appLabels.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attribution").font(.subheadline.bold())
            HStack(alignment: .top, spacing: 12) {
                customerField
                if !selectedCustomerID.isEmpty {
                    projectField
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var customerField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Customer").font(.caption).foregroundStyle(.secondary)
            if creatingCustomer {
                HStack {
                    TextField("Customer name", text: $newCustomerName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { confirmCreateCustomer() }
                    Button("Add") { confirmCreateCustomer() }
                        .disabled(newCustomerName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        creatingCustomer = false
                        newCustomerName = ""
                    }
                }
            } else {
                HStack {
                    Picker("", selection: $selectedCustomerID) {
                        Text("Unassigned").tag("")
                        ForEach(localCustomers) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button("+ New") { creatingCustomer = true }
                }
            }
        }
    }

    @ViewBuilder
    private var projectField: some View {
        let avail = localProjects.filter { $0.customerID == selectedCustomerID }
        VStack(alignment: .leading, spacing: 4) {
            Text("Project").font(.caption).foregroundStyle(.secondary)
            if creatingProject {
                HStack {
                    TextField("Project name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { confirmCreateProject() }
                    Button("Add") { confirmCreateProject() }
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        creatingProject = false
                        newProjectName = ""
                    }
                }
            } else {
                HStack {
                    Picker("", selection: $selectedProjectID) {
                        Text("(no project)").tag("")
                        ForEach(avail) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button("+ New") { creatingProject = true }
                }
            }
        }
    }

    private func confirmCreateCustomer() {
        let name = newCustomerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let palette = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6"]
        let color = palette[localCustomers.count % palette.count]
        let c = Customer(id: UUID().uuidString, name: name, color: color, createdAt: Date())
        do {
            try database.upsert(c)
            localCustomers.append(c)
            localCustomers.sort { $0.name < $1.name }
            selectedCustomerID = c.id
            selectedProjectID = ""
            creatingCustomer = false
            newCustomerName = ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func confirmCreateProject() {
        guard !selectedCustomerID.isEmpty else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let p = Project(id: UUID().uuidString, customerID: selectedCustomerID, name: name, color: nil, createdAt: Date())
        do {
            try database.upsert(p)
            localProjects.append(p)
            localProjects.sort { $0.name < $1.name }
            selectedProjectID = p.id
            creatingProject = false
            newProjectName = ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps in the foreground").font(.subheadline.bold())
            ForEach(appBreakdown) { a in
                HStack {
                    Image(systemName: "app")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(a.name)
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                    Text(formatDuration(a.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }
        }
    }

    @ViewBuilder
    private var urlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pages visited").font(.subheadline.bold())
            ForEach(urlBreakdown) { u in
                HStack {
                    Image(systemName: "link")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(u.id)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(formatDuration(u.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if session.customerID != nil {
                Button("Clear", role: .destructive) {
                    onClear()
                    dismiss()
                }
            }
            Button("Save") {
                let cid = selectedCustomerID.isEmpty ? nil : selectedCustomerID
                let pid = selectedProjectID.isEmpty ? nil : selectedProjectID
                onSave(cid, pid)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCustomerID.isEmpty)
        }
    }

    private var headerDetailLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        let date = f.string(from: session.startedAt)
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let start = tf.string(from: session.startedAt)
        let end = session.endedAt.map { tf.string(from: $0) } ?? "…"
        let mins = Int(((session.durationSeconds ?? 0) / 60).rounded())
        return "\(date)  ·  \(start)–\(end)  ·  \(mins) min"
    }

    private var appLabels: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for bid in session.voipApps {
            if let label = MicMonitor.displayName(forBundleID: bid), !seen.contains(label) {
                seen.insert(label); out.append(label)
            }
        }
        return out
    }

    private func loadBreakdowns() {
        // Use "now" as the end bound for ongoing sessions so users can still
        // see what was in the foreground during a call in progress.
        let endBound = session.endedAt ?? Date()
        do {
            let samples = try database.samplesOverlapping(start: session.startedAt, end: endBound)
            let sampleInterval = Double(AppSettings.sampleIntervalSeconds)

            var appCounts: [String: (name: String, count: Int)] = [:]
            var urlCounts: [String: Int] = [:]
            for s in samples {
                if let bid = s.appBundleID {
                    let label = s.appName ?? bid
                    let cur = appCounts[bid] ?? (name: label, count: 0)
                    appCounts[bid] = (cur.name, cur.count + 1)
                }
                if let url = s.chromeURL, let prefix = RuleMatcher.urlPathPrefix(url, segments: 2) {
                    urlCounts[prefix, default: 0] += 1
                }
            }
            appBreakdown = appCounts.map { (bid, v) in
                AppUsage(id: bid, name: v.name, seconds: Double(v.count) * sampleInterval)
            }
            .sorted { $0.seconds > $1.seconds }
            urlBreakdown = Array(urlCounts.map { URLUsage(id: $0.key, seconds: Double($0.value) * sampleInterval) }
                .sorted { $0.seconds > $1.seconds }
                .prefix(8))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
