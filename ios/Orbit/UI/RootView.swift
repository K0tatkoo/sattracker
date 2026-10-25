import OrbitCore
import SwiftUI

/// The globe edge to edge, with the chrome floating over it in Liquid Glass:
/// About, the brand and search/alerts in the toolbar, the categories along the
/// bottom, and one sheet at a time (a satellite's card, or a toolbar sheet).
///
/// Where the width is regular (iPad, iPhone Duo open) a sheet would be a
/// centred form over the globe, so the card floats beside it instead (or
/// under it, on a screen taller than it is wide) and the globe stays usable.
/// Only the size class decides, never the device or the orientation: an iPad
/// window narrowed in Split View gets the phone's sheet again.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var size = CGSize.zero
    @State private var chrome = EdgeInsets()

    var body: some View {
        // The measured size is the safe area's; the bars are the insets.
        let screen = CGSize(width: size.width + chrome.leading + chrome.trailing,
                            height: size.height + chrome.top + chrome.bottom)
        let placement = CardPlacement(regular: widthClass == .regular, shortHeight: heightClass == .compact, size: screen)
        // The floating card lives outside the one-sheet slot; the toolbar's
        // sheets still take it, and they put the card away as on the phone.
        let floats = placement.floats
        NavigationStack {
            GlobeView(model: model, active: phase == .active,
                      cardSpace: model.sheet == .card ? placement : nil, chrome: chrome)
                .ignoresSafeArea()
                .background(Color(Palette.of(scheme).bg).ignoresSafeArea())
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                // Under the bars, so its insets are the bars themselves.
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { chrome = $0 }
                .overlay(alignment: .top) { ToastView().padding(.top, 6) }
                .overlay { if model.booting { BootBadge() } }
                .overlay(alignment: placement.alignment) { FloatingCard(placement: placement) }
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
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                        Button("Find a satellite", systemImage: "magnifyingglass") { model.open(.search) }
                            .keyboardShortcut("f")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: Binding(get: { floats && model.sheet == .card ? nil : model.sheet },
                             // Unfolding (or widening the window) takes the
                             // card out of its sheet: that is not a dismissal.
                             set: { if !($0 == nil && floats && model.sheet == .card) { model.sheet = $0 } }),
               onDismiss: { model.sheetDismissed() }) { sheet in
            switch sheet {
            case .card: SatelliteCard(compact: placement.compact)
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

/// How the satellite's card is shown in the space there is.
enum CardPlacement: Equatable {
    /// The phone's glass sheet, pulled up for the passes; this tall at rest.
    case sheet(compact: CGFloat)
    /// A glass panel down the leading side, this wide.
    case side(width: CGFloat)
    /// A glass panel along the bottom, this tall.
    case bottom(height: CGFloat)

    init(regular: Bool, shortHeight: Bool, size: CGSize) {
        // A phone on its side (or a closed iPhone Duo): even the short sheet
        // would cover most of the globe and the bar beside it, so the card
        // stands down the side instead, as on an iPad.
        if shortHeight, size.width > size.height {
            self = .side(width: min(380, max(300, size.width * 0.42)))
            return
        }
        guard regular, size.width > 0 else {
            // A short screen (a closed iPhone Duo, a phone on its side) gets
            // the short card, so the globe and the bars beside it stay in view.
            self = .sheet(compact: size.height > 0 && size.height < 720 ? SatelliteCard.short : SatelliteCard.compact)
            return
        }
        // Beside the globe where the screen is wider than tall (the globe fits
        // the height, so the width has room to spare), under it otherwise.
        if size.width > size.height, size.width >= 800 {
            self = .side(width: min(400, max(340, size.width * 0.3)))
        } else {
            self = .bottom(height: min(max(390, size.height * 0.36), 480))
        }
    }

    var alignment: Alignment {
        if case .side = self { .topLeading } else { .bottom }
    }

    /// A panel of its own rather than a sheet.
    var floats: Bool {
        if case .sheet = self { false } else { true }
    }

    var compact: CGFloat {
        if case .sheet(let height) = self { height } else { SatelliteCard.compact }
    }
}

/// The card where a sheet would be a modal form: a glass panel that leaves the
/// globe free to turn, zoom and tap (another dot and the card follows it).
private struct FloatingCard: View {
    let placement: CardPlacement
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.sheet == .card {
                panel
            }
        }
        .animation(.smooth(duration: 0.3), value: model.sheet == .card)
    }

    @ViewBuilder private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        switch placement {
        case .sheet:
            EmptyView()
        case .side(let width):
            SatelliteCard(floating: true)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .glassEffect(.regular, in: shape)
                .padding([.leading, .top], 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
        case .bottom(let height):
            SatelliteCard(floating: true)
                .frame(maxWidth: 640)
                .frame(height: height)
                .glassEffect(.regular, in: shape)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
/// Centred where they all fit (an iPad), scrolling where they do not.
private struct CategoryBar: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(model.categories) { CategoryChip(category: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .frame(minWidth: width)
        }
        .scrollClipDisabled()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
