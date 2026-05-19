import SwiftUI

struct CustomersView: View {
    @EnvironmentObject private var state: AppState
    @State private var customers: [Customer] = []
    @State private var rules: [Rule] = []
    @State private var selectedCustomerID: String?
    @State private var newCustomerName: String = ""
    @State private var showingAddRule = false
    @State private var loadError: String?

    var body: some View {
        NavigationSplitView {
            customerSidebar
        } detail: {
            customerDetail
        }
        .navigationTitle("Customers & Rules")
        .onAppear { reload() }
        .alert("Database error", isPresented: errorBinding) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    @ViewBuilder
    private var customerSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedCustomerID) {
                ForEach(customers) { customer in
                    HStack {
                        Circle()
                            .fill(Color(hex: customer.color) ?? .blue)
                            .frame(width: 10, height: 10)
                        Text(customer.name)
                    }
                    .tag(customer.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            delete(customer)
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
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    @ViewBuilder
    private var customerDetail: some View {
        if let customerID = selectedCustomerID,
           let customer = customers.first(where: { $0.id == customerID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(customer.name)
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        showingAddRule = true
                    } label: {
                        Label("Add rule", systemImage: "plus")
                    }
                }
                .padding()

                Divider()

                if rules.isEmpty {
                    Spacer()
                    Text("No rules yet. Click \"Add rule\" to map activity to \(customer.name).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    Table(rules) {
                        TableColumn("Kind") { rule in
                            Text(rule.kind.label)
                        }
                        .width(min: 160, ideal: 180)

                        TableColumn("Pattern") { rule in
                            Text(rule.pattern)
                                .font(.body.monospaced())
                        }
                        .width(min: 200, ideal: 320)

                        TableColumn("Priority") { rule in
                            Text("\(rule.priority)")
                                .monospacedDigit()
                        }
                        .width(70)

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
                }
            }
            .sheet(isPresented: $showingAddRule) {
                AddRuleSheet(
                    customerID: customer.id,
                    availableProjects: (try? state.database.projects(forCustomer: customer.id)) ?? []
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

    private func reload() {
        do {
            customers = try state.database.allCustomers()
            if let id = selectedCustomerID {
                rules = try state.database.rules(forCustomer: id)
            } else {
                rules = []
            }
            if selectedCustomerID == nil, let first = customers.first {
                selectedCustomerID = first.id
                rules = try state.database.rules(forCustomer: first.id)
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
}

private struct AddRuleSheet: View {
    let customerID: String
    let availableProjects: [Project]
    let onSave: (Rule) -> Void

    @Environment(\.dismiss) private var dismiss
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
                Picker("Project", selection: $projectID) {
                    Text("(none — customer level)").tag("")
                    ForEach(availableProjects) { p in
                        Text(p.name).tag(p.id)
                    }
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
        case .emailDomain:
            return "Domain of meeting attendees (Phase 4 — meetings not yet imported)."
        }
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
