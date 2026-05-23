import SwiftUI

/// Shared customer / project picker. Replaces ad-hoc `Picker` menus everywhere
/// in the app so the look and behaviour stay consistent:
///   • CC items are grouped under a "Command Center" header (with a "·  CC"
///     suffix), local items under a "Local" header.
///   • A search field filters by case-insensitive substring on the label.
///   • An optional "Sync from Command Center" footer triggers a sync when the
///     user has CC configured. Hidden otherwise.
///   • Empty-selection / clear row is configurable via `allowsClear` and
///     `clearLabel` (used for "Choose…", "All customers", "(no project)",
///     "(use rule)", etc.).
///
/// Trigger looks like a standard macOS popup button. Clicking opens a popover
/// (not the system menu) so we can show a search field inside.
struct SearchableEntityPicker: View {
    struct Item: Identifiable, Hashable {
        let id: String
        let label: String
        let isExternal: Bool
    }

    let items: [Item]
    @Binding var selectedID: String
    var placeholder: String = "Choose…"
    var allowsClear: Bool = true
    var clearLabel: String = "Choose…"
    // Sync footer. Caller decides visibility — typically `canSync = state.commandCenterHasToken && commandCenterEnabled`.
    var canSync: Bool = false
    var isSyncing: Bool = false
    var lastSyncedAt: Date? = nil
    var onSync: (() -> Void)? = nil

    @State private var isPresented = false
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(triggerLabel)
                    .foregroundStyle(selectedID.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                if selectedID.isEmpty == false, selectedIsExternal {
                    CommandCenterBadge()
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 180)
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
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverBody
        }
        .onChange(of: isPresented) { _, newValue in
            if newValue {
                query = ""
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    private var triggerLabel: String {
        guard let item = items.first(where: { $0.id == selectedID }) else { return placeholder }
        return item.label
    }

    private var selectedIsExternal: Bool {
        items.first(where: { $0.id == selectedID })?.isExternal ?? false
    }

    @ViewBuilder
    private var popoverBody: some View {
        let filtered = filteredItems
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { commitFirstMatch(filtered) }
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

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if allowsClear {
                        row(
                            id: "",
                            label: clearLabel,
                            isExternal: false,
                            isClear: true
                        )
                        Divider()
                    }

                    let cc = filtered.filter { $0.isExternal }
                    let locals = filtered.filter { !$0.isExternal }

                    if !cc.isEmpty {
                        sectionHeader("Command Center")
                        ForEach(cc) { item in
                            row(id: item.id, label: item.label, isExternal: true, isClear: false)
                        }
                    }
                    if !locals.isEmpty {
                        if !cc.isEmpty { Divider().padding(.vertical, 2) }
                        sectionHeader("Local")
                        ForEach(locals) { item in
                            row(id: item.id, label: item.label, isExternal: false, isClear: false)
                        }
                    }

                    if filtered.isEmpty {
                        Text(items.isEmpty ? "Nothing to choose from yet." : "No matches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 80, maxHeight: 280)

            if canSync, onSync != nil {
                Divider()
                syncFooter
            }
        }
        .frame(width: 280)
    }

    private var filteredItems: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.label.lowercased().contains(q) }
    }

    private func commitFirstMatch(_ filtered: [Item]) {
        // Sort puts CC first only if labels match — instead match by overall first result.
        guard let first = filtered.first else { return }
        selectedID = first.id
        isPresented = false
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

    @ViewBuilder
    private func row(id: String, label: String, isExternal: Bool, isClear: Bool) -> some View {
        let isSelected = selectedID == id
        Button {
            selectedID = id
            isPresented = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(label)
                    .foregroundStyle(isClear ? .secondary : .primary)
                    .lineLimit(1)
                if isExternal { CommandCenterBadge() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear
        )
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
                Label("Sync from Command Center", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(isSyncing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
