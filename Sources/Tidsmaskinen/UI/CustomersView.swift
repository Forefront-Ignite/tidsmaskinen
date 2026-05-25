import SwiftUI

struct CustomersView: View {
    @EnvironmentObject private var state: AppState
    @State private var customers: [Customer] = []
    @State private var rules: [Rule] = []
    @State private var customerProjects: [Project] = []
    @State private var selectedCustomerID: String?
    @State private var newCustomerName: String = ""
    @State private var newProjectName: String = ""
    @State private var showingAddRule = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
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
        .navigationTitle("Customers & Rules")
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
                ForEach(customers) { customer in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: customer.displayColor) ?? .blue)
                            .frame(width: 10, height: 10)
                        Text(customer.name)
                        if customer.isExternal {
                            CommandCenterBadge()
                        }
                    }
                    .tag(customer.id)
                    .contextMenu {
                        if customer.isExternal {
                            Text("Synced from Command Center")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Delete", role: .destructive) {
                                delete(customer)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

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
    private var customerDetail: some View {
        if let customerID = selectedCustomerID,
           let customer = customers.first(where: { $0.id == customerID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: customer.displayColor) ?? .blue)
                            .frame(width: 14, height: 14)
                        Text(customer.name)
                            .font(.title2.bold())
                        if customer.isExternal {
                            CommandCenterBadge()
                                .help("Synced from Command Center. Name and projects are read-only here.")
                        }
                        Spacer()
                        Button {
                            showingAddRule = true
                        } label: {
                            Label("Add rule", systemImage: "plus")
                        }
                    }
                    .padding()

                    Divider()

                    projectsSection(for: customer)

                    Divider()

                    rulesSection(for: customer)
                }
            }
            .sheet(isPresented: $showingAddRule) {
                AddRuleSheet(
                    customerID: customer.id,
                    availableProjects: customerProjects
                ) { rule in
                    do {
                        try state.database.upsert(rule)
                        reload()
                    } catch {
                        loadError = error.localizedDescription
                    }
                }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Projects")
                    .font(.headline)
                Text("(\(customerProjects.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if customerProjects.isEmpty {
                Text(customer.isExternal
                     ? "No projects synced from Command Center yet."
                     : "No projects yet. Add one below to attribute work at the project level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(customerProjects) { project in
                        projectRow(project, customerIsExternal: customer.isExternal)
                    }
                }
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
        .padding()
    }

    @ViewBuilder
    private func projectRow(_ project: Project, customerIsExternal: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: project.displayColor) ?? .blue)
                .frame(width: 8, height: 8)
            Text(project.name)
                .font(.body)
            if project.isExternal {
                CommandCenterBadge()
            }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private func rulesSection(for customer: Customer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Rules")
                    .font(.headline)
                Text("(\(rules.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if rules.isEmpty {
                Text("No rules yet. Click \"Add rule\" to map activity to \(customer.name).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Table(rules) {
                    TableColumn("Kind") { rule in
                        Text(rule.kind.label)
                    }
                    .width(min: 140, ideal: 160)

                    TableColumn("Pattern") { rule in
                        Text(rule.pattern)
                            .font(.body.monospaced())
                    }
                    .width(min: 200, ideal: 320)

                    TableColumn("Project") { rule in
                        Text(projectName(for: rule.projectID) ?? "—")
                            .foregroundStyle(rule.projectID == nil ? .secondary : .primary)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Priority") { rule in
                        Text("\(rule.priority)")
                            .monospacedDigit()
                    }
                    .width(60)

                    TableColumn("") { rule in
                        Button(role: .destructive) {
                            delete(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(40)
                }
                .frame(minHeight: 180)
            }
        }
        .padding()
    }

    private func projectName(for id: String?) -> String? {
        guard let id else { return nil }
        return customerProjects.first { $0.id == id }?.name
    }

    private func reload() {
        do {
            customers = try state.database.allCustomers()
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

private struct AddRuleSheet: View {
    let customerID: String
    let availableProjects: [Project]
    let onSave: (Rule) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var kind: Rule.Kind = .gitRepoSlug
    @State private var pattern: String = ""
    @State private var priority: Int = 100
    @State private var projectID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New rule")
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

            if !availableProjects.isEmpty {
                HStack {
                    Text("Project").font(.subheadline.bold())
                    SearchableEntityPicker(
                        items: availableProjects.map {
                            .init(id: $0.id, label: $0.name, isExternal: $0.isExternal)
                        },
                        selectedID: $projectID,
                        placeholder: "(none — customer level)",
                        allowsClear: true,
                        clearLabel: "(none — customer level)",
                        canSync: AppSettings.commandCenterEnabled && state.commandCenterHasToken,
                        isSyncing: state.commandCenterIsSyncing,
                        lastSyncedAt: state.commandCenterLastSyncAt,
                        onSync: { Task { await state.refreshCommandCenter() } }
                    )
                }
            }

            Stepper(value: $priority, in: 0...1000, step: 10) {
                LabeledContent("Priority") {
                    Text("\(priority)").monospacedDigit()
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let r = Rule(
                        id: UUID().uuidString,
                        customerID: customerID,
                        projectID: projectID.isEmpty ? nil : projectID,
                        kind: kind,
                        pattern: trimmed,
                        priority: priority,
                        createdAt: Date()
                    )
                    onSave(r)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
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
        }
    }
}

/// Small "CC" capsule shown next to customers and projects synced from
/// Command Center. Used in CustomersView, DiscoverView, and anywhere else the
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

extension Color {
    init?(hex: String?) {
        guard let hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines), hex.hasPrefix("#"),
              hex.count == 7 else { return nil }
        let scanner = Scanner(string: String(hex.dropFirst()))
        var rgb: UInt64 = 0
        guard scanner.scanHexInt64(&rgb) else { return nil }
        self = Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
