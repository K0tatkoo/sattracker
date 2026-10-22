import OrbitCore
import SwiftUI

/// The globe edge to edge, with the chrome floating over it in Liquid Glass:
/// About, the brand and search/alerts in the toolbar, the categories along the
/// bottom, and one sheet at a time (a satellite's card, or a toolbar sheet).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            GlobeView(model: model, active: phase == .active)
                .ignoresSafeArea()
                .background(Color(Palette.of(scheme).bg).ignoresSafeArea())
                .overlay(alignment: .top) { ToastView().padding(.top, 6) }
                .overlay { if model.booting { BootBadge() } }
                .safeAreaInset(edge: .bottom) { CategoryBar().padding(.bottom, 6) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("About Orbit", systemImage: "info") { model.open(.about) }
                    }
                    ToolbarItem(placement: .principal) { Brand() }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Pass alerts", systemImage: model.alerts.watched.isEmpty ? "bell" : "bell.badge") {
                            model.open(.alerts)
                        }
                        Button("Find a satellite", systemImage: "magnifyingglass") { model.open(.search) }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: Binding(get: { model.sheet }, set: { model.sheet = $0 }), onDismiss: { model.sheetDismissed() }) { sheet in
            switch sheet {
            case .card: SatelliteCard()
            case .search: SearchSheet()
            case .alerts: AlertsSheet()
            case .about: AboutSheet()
            }
        }
        // Inactive is only a moment on the way to the background or back
        // (or Control Center): acting on it planned the alerts twice a switch.
        .onChange(of: phase, initial: true) { _, now in
            if now != .inactive { model.setActive(now == .active) }
        }
        .onOpenURL { model.open(url: $0) }
        .sensoryFeedback(.selection, trigger: model.selectedNorad)
        .task { model.start() }
        // Outermost, so the sheets get it too: every filled control is the one
        // flat violet, as on the sites and the Android apps.
        .tint(Color.accentColor)
    }
}

/// "ORBIT." with the mark, as on the page's top bar.
private struct Brand: View {
    var body: some View {
        HStack(spacing: 7) {
            OrbitMark()
                .frame(width: 20, height: 20)
                .foregroundStyle(.tint)
            Text("ORBIT\(Text(".").foregroundStyle(.tint))")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .tracking(1.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orbit")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The categories, as glass chips: lit in the category's colour when shown.
private struct CategoryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(model.categories) { CategoryChip(category: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .scrollClipDisabled()
    }
}

private struct CategoryChip: View {
    let category: SatCategory
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let on = model.enabled.contains(category.id)
        let color = Color.category(category.id, dark: scheme == .dark)
        Button { model.toggle(category) } label: {
            HStack(spacing: 7) {
                if model.loading.contains(category.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    ZStack {
                        Circle().fill(on ? color : .clear)
                        Circle().strokeBorder(color, lineWidth: 1.5)
                    }
                    .frame(width: 9, height: 9)
                }
                Text(category.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(on ? .primary : .secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(color.opacity(scheme == .dark ? 0.22 : 0.16)).interactive() : .regular.interactive(),
                     in: .capsule)
        .animation(.snappy, value: on)
        .accessibilityLabel(category.label)
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                Text(toast.text)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.smooth, value: model.toast)
    }
}

private struct BootBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Contacting satellites…").font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .transition(.opacity)
    }
}
