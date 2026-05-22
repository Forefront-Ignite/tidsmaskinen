import SwiftUI

/// Shared customer + project picker used by every "assign attribution" sheet in
/// the app (Discover assignment, Calls call-detail sheet, Timeline reattribute
/// popover). Owns the inline-creation state so a freshly-added customer or
/// project appears in the menu without the parent re-fetching.
///
/// Layout matches the original Discover sheet:
///   • Customer picker splits into "Command Center" (with `·  CC` suffix) and
///     "Local" sections, both sorted by name. A "+ New" button sits next to the
///     picker.
///   • Project picker filters projects to the chosen customer, with the same
///     CC/Local split. "+ New Project" is disabled (with help text) when the
///     chosen customer is external — projects under a CC customer must come
///     from Command Center too.
struct AttributionPickerSection: View {
    let customers: [Customer]
    let projects: [Project]
    @Binding var selectedCustomerID: String      // empty string == nothing selected
    @Binding var selectedProjectID: String       // empty string == "(no project)"
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    /// Label to show in the customer picker when nothing is selected. Defaults
    /// to "Choose…"; Timeline's Claude blocks pass "(use rule)" instead.
    var emptyCustomerLabel: String = "Choose…"
    /// Optional error text rendered below the pickers. Updated when inline
    /// creation throws.
    @Binding var error: String?

    @State private var localCustomers: [Customer] = []
    @State private var localProjects: [Project] = []
    @State private var creatingCustomer = false
    @State private var creatingProject = false
    @State private var newCustomerName = ""
    @State private var newProjectName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            customerPicker
            if !selectedCustomerID.isEmpty {
                projectPicker
            }
        }
        .onAppear {
            localCustomers = customers
            localProjects = projects
        }
        .onChange(of: customers) { _, newValue in
            localCustomers = newValue
        }
        .onChange(of: projects) { _, newValue in
            localProjects = newValue
        }
    }

    @ViewBuilder
    private var customerPicker: some View {
        let cc = localCustomers.filter { $0.isExternal }.sorted { $0.name < $1.name }
        let locals = localCustomers.filter { !$0.isExternal }.sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 6) {
            Text("Customer").font(.subheadline.bold())
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
                    Picker("", selection: Binding(
                        get: { selectedCustomerID },
                        set: { newValue in
                            selectedCustomerID = newValue
                            // Changing customer wipes any stale project choice.
                            selectedProjectID = ""
                        }
                    )) {
                        Text(emptyCustomerLabel).tag("")
                        if !cc.isEmpty {
                            Section("Command Center") {
                                ForEach(cc) { c in
                                    Text("\(c.name)  ·  CC").tag(c.id)
                                }
                            }
                        }
                        if !locals.isEmpty {
                            Section("Local") {
                                ForEach(locals) { c in
                                    Text(c.name).tag(c.id)
                                }
                            }
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
        let avail = localProjects.filter { $0.customerID == selectedCustomerID }
        let cc = avail.filter { $0.isExternal }.sorted { $0.name < $1.name }
        let locals = avail.filter { !$0.isExternal }.sorted { $0.name < $1.name }
        let customerIsExternal = localCustomers.first { $0.id == selectedCustomerID }?.isExternal == true
        VStack(alignment: .leading, spacing: 6) {
            Text("Project").font(.subheadline.bold())
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
                        if !cc.isEmpty {
                            Section("Command Center") {
                                ForEach(cc) { p in
                                    Text("\(p.name)  ·  CC").tag(p.id)
                                }
                            }
                        }
                        if !locals.isEmpty {
                            Section("Local") {
                                ForEach(locals) { p in
                                    Text(p.name).tag(p.id)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button("+ New") { creatingProject = true }
                        .disabled(customerIsExternal)
                        .help(customerIsExternal
                              ? "Projects under a Command Center customer come from Command Center too."
                              : "")
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
            selectedProjectID = ""
            creatingCustomer = false
            newCustomerName = ""
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func confirmCreateProject() {
        guard !selectedCustomerID.isEmpty else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let p = try onCreateProject(selectedCustomerID, name)
            localProjects.append(p)
            localProjects.sort { $0.name < $1.name }
            selectedProjectID = p.id
            creatingProject = false
            newProjectName = ""
        } catch let e {
            error = e.localizedDescription
        }
    }
}
