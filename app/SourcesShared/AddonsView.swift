import SwiftUI

/// Add-ons installed on your account, read live from the engine. You can remove a non-default addon
/// here, and reorder them by long-press-drag; the order is persisted in UserDefaults under
/// `addonOrder` (comma-separated addon transportUrls). CoreBridge reads the same key when it builds
/// `boardRows`, so the catalog rows on Home/Discover follow this order too.
struct AddonsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager

    /// Persisted custom order of addon transportUrls. Empty = fall back to the engine's own order.
    @AppStorage("addonOrder") private var addonOrderRaw: String = ""

    /// The transportUrl currently being dragged, used to lift the source row visually.
    @State private var draggingURL: String?

    /// `core.addons` re-sorted according to the persisted order. Addons not present in the saved
    /// order (newly installed) keep their engine position at the end, so a fresh one doesn't jump.
    private var orderedAddons: [CoreDescriptor] {
        let order = addonOrderRaw.split(separator: ",").map(String.init)
        guard !order.isEmpty else { return core.addons }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return core.addons.sorted {
            (index[$0.transportUrl] ?? Int.max) < (index[$1.transportUrl] ?? Int.max)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Add-ons").screenTitleStyle()
                    if !account.isSignedIn {
                        hint("Sign in to manage your add-ons. They sync from the Stremio web or mobile app.")
                    } else if core.addons.isEmpty {
                        hint("No add-ons found on your account yet. Install them from the Stremio web or mobile app and they will sync down on next launch.")
                    } else {
                        Text("Long-press and drag to reorder. The order applies to catalogs on Home and Discover.")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .padding(.bottom, Theme.Space.xs)
                        ForEach(orderedAddons) { addon in
                            addonRow(addon)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
    }

    private func addonRow(_ addon: CoreDescriptor) -> some View {
        let url = addon.transportUrl
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: addon.providesStreams ? "play.rectangle.on.rectangle.fill" : "puzzlepiece.extension.fill")
                .font(.system(size: 36))
                .foregroundStyle(addon.providesStreams ? Theme.Palette.accent : Theme.Palette.textTertiary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(addon.manifest.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text(addon.capabilities).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Text(addon.host).font(.system(size: 16, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.sm)
            if !addon.isProtected {
                Button { core.uninstallAddon(addon) } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                    .fixedSize()
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        // Lift the row visually while it's the drag source.
        .opacity(draggingURL == url ? 0.6 : 1)
        .scaleEffect(draggingURL == url ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: draggingURL)
        // iOS 16+: drag the addon transportUrl as a String payload.
        .draggable(url) {
            // Drag preview: a small chip with the addon name so the user sees what's moving.
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(addon.manifest.name)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .onAppear { draggingURL = url }
        }
        // Drop onto a row → insert the dragged addon AT this row's position.
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first else { return false }
            move(dragged, to: url)
            draggingURL = nil
            return true
        }
    }

    /// Reorders `dragged` so it lands at the position currently occupied by `target`.
    private func move(_ dragged: String, to target: String) {
        var order = orderedAddons.map { $0.transportUrl }
        guard let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target),
              from != to else { return }
        order.remove(at: from)
        order.insert(dragged, at: to)
        addonOrderRaw = order.joined(separator: ",")
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.top, Theme.Space.sm)
    }
}
