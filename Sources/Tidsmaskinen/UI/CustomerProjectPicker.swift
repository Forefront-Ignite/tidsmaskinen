import SwiftUI

/// Combined Customer · Project picker. A single trigger that opens one popover
/// showing every customer with its projects nested underneath. Selecting a
/// customer row attributes at the customer level; selecting a project row sets
/// both customer and project in one click.
///
/// Replaces the older "Customer picker → then Project picker" two-step flow.
/// Inline `+ New customer` and `+ New project` creation happens inside the
/// popover so the menu doesn't have to close and re-open.
struct CustomerProjectPicker: View {
    let customers: [Customer]
    let projects: [Project]
    @Binding var selectedCustomerID: String   // "" == nothing selected
    @Binding var selectedProjectID: String    // "" == customer-level (no project)

    /// Inline create hooks. Pass nil to disable the "+ New" affordances.
    var onCreateCustomer: ((String) throws -> Customer)?
    var onCreateProject: ((String, String) throws -> Project)?

    /// Label shown in the trigger when nothing is selected. Defaults to "Choose…".
    /// Timeline's Claude blocks pass "(use rule)".
    var emptyLabel: String = "Choose…"

    /// Allow clearing back to the empty state via a row at the top of the list.
    var allowsClear: Bool = true

    /// Open the popover automatically the first time the picker appears. Used
    /// by attribution sheets so the user lands directly on the search field.
    var autoOpen: Bool = false

    // Sync footer (mirrors SearchableEntityPicker).
    var canSync: Bool = false
    var isSyncing: Bool = false
    var lastSyncedAt: Date? = nil
    var onSync: (() -> Void)? = nil

    @Binding var error: String?

    @State private var isPresented = false
    @State private var didAutoOpen = false
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @State private var creatingCustomer = false
    @State private var newCustomerName = ""
    @State private var creatingProjectUnder: String? = nil
    @State private var newProjectName = ""

    /// Shadow copies so an inline-created customer/project shows up immediately
    /// in the trigger and the popover even though the parent view hasn't
    /// reloaded its own `customers`/`projects` arrays.
    @State private var localCustomers: [Customer] = []
    @State private var localProjects: [Project] = []

    private var selectedCustomer: Customer? {
        localCustomers.first { $0.id == selectedCustomerID }
    }

    private var selectedProject: Project? {
        guard !selectedProjectID.isEmpty else { return nil }
        return localProjects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverBody
                .onAppear {
                    // Focus on the next runloop tick — SwiftUI installs the
                    // popover view hierarchy slightly after this onAppear fires,
                    // and `searchFocused = true` posted synchronously gets
                    // dropped because the TextField isn't in the responder
                    // chain yet.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        searchFocused = true
                    }
                }
        }
        .onChange(of: isPresented) { _, newValue in
            if newValue {
                query = ""
                creatingCustomer = false
                creatingProjectUnder = nil
                newCustomerName = ""
                newProjectName = ""
            }
        }
        .onAppear {
            localCustomers = customers
            localProjects = projects
            if autoOpen, !didAutoOpen {
                didAutoOpen = true
                // Delay one runloop — opening the popover before the picker's
                // own button is laid out anchors the popover off-screen.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    isPresented = true
                }
            }
        }
        .onChange(of: customers) { _, newValue in
            localCustomers = newValue
        }
        .onChange(of: projects) { _, newValue in
            localProjects = newValue
        }
    }

    // MARK: - Trigger

    @ViewBuilder
    private var trigger: some View {
        HStack(spacing: 6) {
            triggerText
            if let c = selectedCustomer, c.isExternal {
                CommandCenterBadge()
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var triggerText: some View {
        if let customer = selectedCustomer {
            HStack(spacing: 4) {
                Text(customer.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let project = selectedProject {
                    Text("·").foregroundStyle(.tertiary)
                    Text(project.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        } else {
            Text(emptyLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Popover

    @ViewBuilder
    private var popoverBody: some View {
        VStack(spacing: 0) {
            searchHeader

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if allowsClear {
                        clearRow
                        Divider()
                    }

                    let groups = matchingGroups()
                    let ccGroups = groups.filter { $0.customer.isExternal }
                    let localGroups = groups.filter { !$0.customer.isExternal }

                    if !ccGroups.isEmpty {
                        sectionHeader("Command Center")
                        ForEach(ccGroups) { group in
                            customerSection(group)
                        }
                    }
                    if !localGroups.isEmpty {
                        if !ccGroups.isEmpty { Divider().padding(.vertical, 2) }
                        sectionHeader("Local")
                        ForEach(localGroups) { group in
                            customerSection(group)
                        }
                    }

                    if groups.isEmpty {
                        Text(customers.isEmpty
                             ? "No customers yet — add one below."
                             : "No matches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 360)

            if onCreateCustomer != nil {
                Divider()
                newCustomerFooter
            }

            if canSync, onSync != nil {
                Divider()
                syncFooter
            }
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private var searchHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search customers or projects", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { commitFirstMatch() }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var clearRow: some View {
        let isSelected = selectedCustomerID.isEmpty
        Button {
            selectedCustomerID = ""
            selectedProjectID = ""
            isPresented = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(emptyLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    // MARK: - Customer + project rows

    private struct CustomerGroup: Identifiable {
        let customer: Customer
        let projects: [Project]
        var id: String { customer.id }
    }

    /// Build the list of `(customer, [projects])` groups visible under the
    /// current search query. A group is kept when:
    ///   * the search is empty
    ///   * the customer's name matches
    ///   * at least one of its projects matches (and the visible project list
    ///     narrows down to just those matches)
    private func matchingGroups() -> [CustomerGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sortedCustomers = localCustomers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return sortedCustomers.compactMap { customer in
            let customerMatches = q.isEmpty || customer.name.lowercased().contains(q)
            let allCustomerProjects = localProjects
                .filter { $0.customerID == customer.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let visibleProjects: [Project]
            if q.isEmpty || customerMatches {
                visibleProjects = allCustomerProjects
            } else {
                visibleProjects = allCustomerProjects.filter {
                    $0.name.lowercased().contains(q)
                }
            }
            if !customerMatches, visibleProjects.isEmpty { return nil }
            return CustomerGroup(customer: customer, projects: visibleProjects)
        }
    }

    @ViewBuilder
    private func customerSection(_ group: CustomerGroup) -> some View {
        customerRow(group.customer)
        ForEach(group.projects) { project in
            projectRow(customer: group.customer, project: project)
        }
        if !group.customer.isExternal, onCreateProject != nil {
            if creatingProjectUnder == group.customer.id {
                inlineCreateProjectField(under: group.customer)
            } else {
                Button {
                    newProjectName = ""
                    creatingProjectUnder = group.customer.id
                    creatingCustomer = false
                } label: {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 12)
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .frame(width: 16)
                        Text("New project")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func customerRow(_ customer: Customer) -> some View {
        let isSelected = selectedCustomerID == customer.id && selectedProjectID.isEmpty
        Button {
            selectedCustomerID = customer.id
            selectedProjectID = ""
            isPresented = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Circle()
                    .fill(Color(hex: customer.displayColor) ?? .blue)
                    .frame(width: 8, height: 8)
                Text(customer.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if customer.isExternal {
                    CommandCenterBadge()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func projectRow(customer: Customer, project: Project) -> some View {
        let isSelected = selectedCustomerID == customer.id && selectedProjectID == project.id
        Button {
            selectedCustomerID = customer.id
            selectedProjectID = project.id
            isPresented = false
        } label: {
            HStack(spacing: 6) {
                Spacer().frame(width: 12)
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(project.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if project.isExternal {
                    CommandCenterBadge()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func inlineCreateProjectField(under customer: Customer) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 12)
            Image(systemName: "plus.square")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField("Project name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { confirmCreateProject(under: customer) }
            Button("Add") { confirmCreateProject(under: customer) }
                .controlSize(.small)
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                creatingProjectUnder = nil
                newProjectName = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Footers

    @ViewBuilder
    private var newCustomerFooter: some View {
        if creatingCustomer {
            HStack(spacing: 6) {
                Image(systemName: "plus.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Customer name", text: $newCustomerName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { confirmCreateCustomer() }
                Button("Add") { confirmCreateCustomer() }
                    .controlSize(.small)
                    .disabled(newCustomerName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    creatingCustomer = false
                    newCustomerName = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else {
            Button {
                creatingCustomer = true
                creatingProjectUnder = nil
                newCustomerName = ""
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16)
                    Text("New customer")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var syncFooter: some View {
        HStack(spacing: 8) {
            if isSyncing {
                ProgressView().controlSize(.small)
                Text("Syncing…").font(.caption).foregroundStyle(.secondary)
            } else if let lastSyncedAt {
                Text("Synced \(lastSyncedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Not synced yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onSync?()
            } label: {
                Label("Sync from CC", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(isSyncing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    /// On Return, pick the most relevant row. Prefer an exact-match customer or
    /// project; fall back to the first visible customer.
    private func commitFirstMatch() {
        let groups = matchingGroups()
        guard let firstGroup = groups.first else { return }
        // If the user typed something matching exactly one project across all
        // customers, pick that project.
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            for group in groups {
                if let exact = group.projects.first(where: { $0.name.lowercased() == q }) {
                    selectedCustomerID = group.customer.id
                    selectedProjectID = exact.id
                    isPresented = false
                    return
                }
            }
        }
        selectedCustomerID = firstGroup.customer.id
        selectedProjectID = ""
        isPresented = false
    }

    private func confirmCreateCustomer() {
        guard let onCreateCustomer else { return }
        let name = newCustomerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let c = try onCreateCustomer(name)
            localCustomers.append(c)
            localCustomers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedCustomerID = c.id
            selectedProjectID = ""
            creatingCustomer = false
            newCustomerName = ""
            isPresented = false
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func confirmCreateProject(under customer: Customer) {
        guard let onCreateProject else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let p = try onCreateProject(customer.id, name)
            localProjects.append(p)
            localProjects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedCustomerID = customer.id
            selectedProjectID = p.id
            creatingProjectUnder = nil
            newProjectName = ""
            isPresented = false
        } catch let e {
            error = e.localizedDescription
        }
    }
}
