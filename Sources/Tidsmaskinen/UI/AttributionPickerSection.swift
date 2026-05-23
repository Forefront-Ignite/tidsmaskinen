import SwiftUI

/// Shared customer + project picker used by every "assign attribution" sheet in
/// the app (Discover assignment, Calls call-detail sheet, Timeline reattribute
/// popover). Owns the inline-creation state so a freshly-added customer or
/// project appears in the menu without the parent re-fetching.
///
/// Both selects are rendered by `SearchableEntityPicker` — single source of
/// truth for the CC/Local split, search, and the "Sync from Command Center"
/// footer. "+ New" inline creation lives here so the parent doesn't have to
/// re-fetch after creating a customer or project.
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

    @EnvironmentObject private var state: AppState
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
                    SearchableEntityPicker(
                        items: localCustomers.map {
                            .init(id: $0.id, label: $0.name, isExternal: $0.isExternal)
                        },
                        selectedID: Binding(
                            get: { selectedCustomerID },
                            set: { newValue in
                                selectedCustomerID = newValue
                                // Changing customer wipes any stale project choice.
                                selectedProjectID = ""
                            }
                        ),
                        placeholder: emptyCustomerLabel,
                        allowsClear: true,
                        clearLabel: emptyCustomerLabel,
                        canSync: AppSettings.commandCenterEnabled && state.commandCenterHasToken,
                        isSyncing: state.commandCenterIsSyncing,
                        lastSyncedAt: state.commandCenterLastSyncAt,
                        onSync: { Task { await state.refreshCommandCenter() } }
                    )
                    Button("+ New") { creatingCustomer = true }
                }
            }
        }
    }

    @ViewBuilder
    private var projectPicker: some View {
        let avail = localProjects.filter { $0.customerID == selectedCustomerID }
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
                    SearchableEntityPicker(
                        items: avail.map {
                            .init(id: $0.id, label: $0.name, isExternal: $0.isExternal)
                        },
                        selectedID: $selectedProjectID,
                        placeholder: "(no project)",
                        allowsClear: true,
                        clearLabel: "(no project)",
                        canSync: AppSettings.commandCenterEnabled && state.commandCenterHasToken,
                        isSyncing: state.commandCenterIsSyncing,
                        lastSyncedAt: state.commandCenterLastSyncAt,
                        onSync: { Task { await state.refreshCommandCenter() } }
                    )
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
