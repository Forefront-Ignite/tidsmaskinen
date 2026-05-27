import SwiftUI

/// Shared "assign customer / project" modal. Used by Discover's signal-,
/// series-, and one-off-meeting assignment flows, and the weekly report's
/// meeting-contributor reattribution flow. The picker opens automatically on
/// appear so the user can start typing to search without an extra click.
struct AssignmentSheet: View {
    let title: String
    let subtitle: String
    let customers: [Customer]
    let projects: [Project]
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    let onSave: (String, String?) -> Void

    /// Initial selection. Pre-filling lets the picker open to the current
    /// attribution rather than to "Choose…".
    var initialCustomerID: String = ""
    var initialProjectID: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCustomerID: String = ""
    @State private var selectedProjectID: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            AttributionPickerSection(
                customers: customers,
                projects: projects,
                selectedCustomerID: $selectedCustomerID,
                selectedProjectID: $selectedProjectID,
                onCreateCustomer: onCreateCustomer,
                onCreateProject: onCreateProject,
                autoOpen: true,
                error: $error
            )

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCustomerID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            selectedCustomerID = initialCustomerID
            selectedProjectID = initialProjectID
        }
    }

    private func save() {
        guard !selectedCustomerID.isEmpty else { return }
        onSave(selectedCustomerID, selectedProjectID.isEmpty ? nil : selectedProjectID)
        dismiss()
    }
}
