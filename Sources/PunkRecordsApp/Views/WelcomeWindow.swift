import SwiftUI

struct WelcomeWindow: View {
    @Environment(RecentVaultsStore.self) private var recentsStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            // Left side — branding + actions
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "brain.head.profile")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("PunkRecords")
                        .font(.largeTitle.bold())
                    Text("Version 0.1.0")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                VStack(spacing: 12) {
                    WelcomeActionButton(
                        title: "Create New Knowledge Base...",
                        icon: "plus.square",
                        action: createNewVault
                    )

                    WelcomeActionButton(
                        title: "Open Existing Knowledge Base...",
                        icon: "folder",
                        action: openExistingVault
                    )
                }
                .padding(.bottom, 32)
            }
            .frame(width: 340)
            .padding(.horizontal, 32)

            Divider()

            // Right side — recent vaults
            VStack(alignment: .leading, spacing: 0) {
                if recentsStore.recents.isEmpty {
                    Spacer()
                    ContentUnavailableView(
                        "No Recent Knowledge Bases",
                        systemImage: "clock",
                        description: Text("Knowledge bases you open will appear here")
                    )
                    Spacer()
                } else {
                    List(recentsStore.recents, selection: Binding<RecentVaultsStore.RecentVault.ID?>(
                        get: { nil },
                        set: { id in
                            if let vault = recentsStore.recents.first(where: { $0.id == id }) {
                                openVault(at: vault.url)
                            }
                        }
                    )) { vault in
                        RecentVaultRow(vault: vault)
                            .tag(vault.id)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 280, idealWidth: 320)
        }
        .frame(width: 720, height: 440)
        .background(.ultraThinMaterial)
    }

    private func createNewVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose or create a folder for your new knowledge base"
        panel.prompt = "Create"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(at: url)
    }

    private func openExistingVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for your knowledge base"
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(at: url)
    }

    private func openVault(at url: URL) {
        recentsStore.recordOpen(url)
        openWindow(value: url)
        dismissWindow(id: "welcome")
    }
}

// MARK: - Action Button

private struct WelcomeActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

// MARK: - Recent Vault Row

private struct RecentVaultRow: View {
    let vault: RecentVaultsStore.RecentVault

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                    .font(.body.bold())
                    .lineLimit(1)
                Text(abbreviatedPath(vault.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func abbreviatedPath(_ url: URL) -> String {
        let path = url.path
        if let home = FileManager.default.homeDirectoryForCurrentUser.path as String? {
            return path.replacingOccurrences(of: home, with: "~")
        }
        return path
    }
}

// MARK: - Previews

#Preview("Welcome — With Recents") {
    WelcomeWindow()
        .environment(RecentVaultsStore())
}

#Preview("Welcome — Empty") {
    WelcomeWindow()
        .environment(RecentVaultsStore())
}
