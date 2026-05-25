import SwiftUI

/// Thin labeled wrapper around `CustomerProjectPicker` for the "assign
/// attribution" sheets (Discover assignment, Calls call-detail sheet, Timeline
/// reattribute popover). The picker itself is the single source of truth for
/// the CC/Local split, search, sync footer, and inline creation.
///
/// Kept as a stable API so existing call sites don't have to change as the
/// picker UX evolves. Hides the explicit label entirely when `showsLabel` is
/// false (the call-site adds its own).
struct AttributionPickerSection: View {
    let customers: [Customer]
    let projects: [Project]
    @Binding var selectedCustomerID: String      // empty string == nothing selected
    @Binding var selectedProjectID: String       // empty string == customer-level
    let onCreateCustomer: (String) throws -> Customer
    let onCreateProject: (String, String) throws -> Project
    /// Label to show in the picker trigger when nothing is selected. Defaults
    /// to "Choose…"; Timeline's Claude blocks pass "(use rule)".
    var emptyCustomerLabel: String = "Choose…"
    /// Whether to render the "Customer · Project" caption above the picker.
    var showsLabel: Bool = true
    /// Optional error text rendered below the picker. Updated when inline
    /// creation throws.
    @Binding var error: String?

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel {
                Text("Customer · Project").font(.subheadline.bold())
            }
            CustomerProjectPicker(
                customers: customers,
                projects: projects,
                selectedCustomerID: $selectedCustomerID,
                selectedProjectID: $selectedProjectID,
                onCreateCustomer: onCreateCustomer,
                onCreateProject: onCreateProject,
                emptyLabel: emptyCustomerLabel,
                canSync: AppSettings.commandCenterEnabled && state.commandCenterHasToken,
                isSyncing: state.commandCenterIsSyncing,
                lastSyncedAt: state.commandCenterLastSyncAt,
                onSync: { Task { await state.refreshCommandCenter() } },
                error: $error
            )
        }
    }
}
