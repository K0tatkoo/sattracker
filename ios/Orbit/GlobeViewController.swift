import CoreLocation
import OSLog
import UIKit
import WebKit

/// Shows the page and answers it — the iPhone's MainActivity.kt.
///
/// Two things the Android app does are missing on purpose, because iOS gives
/// no app either one: the GNSS chip's list of satellites in use (and their raw
/// signals), and installing its own updates. The page is told so through
/// `Android.capabilities()` and hides those parts.
final class GlobeViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private let assets = Bundle.main.resourceURL!.appendingPathComponent("assets")
    private lazy var tle = TleRepository(bundled: assets.appendingPathComponent("tle"))
    private let location = LocationProvider()
    private let log = Logger(subsystem: "com.kotatko.sattracker", category: "web")

    private var webView: WKWebView!
    private var loaded = false
    private var webReady = false
    /// The theme the page was last given, so a change is pushed exactly once.
    private var themeShown = ""
    private var lastFix: CLLocation?
    private var locationDenied = false

    private var theme: String { traitCollection.userInterfaceStyle == .dark ? "dark" : "light" }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(self), name: Bridge.handlerName)
        config.allowsInlineMediaPlayback = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        // The page's own surface colour behind it, so nothing white ever
        // flashes before the first frame or at the edges of a rotation.
        let background = UIColor(named: "LaunchBackground")
        web.isOpaque = false
        web.backgroundColor = background
        web.scrollView.backgroundColor = background
        // The page lays itself out under the status bar and home indicator
        // with env(safe-area-inset-*), exactly as on Android's edge-to-edge.
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        #if DEBUG
        web.isInspectable = true   // Safari ▸ Develop ▸ Simulator
        #endif
        webView = web
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        location.onLocation = { [weak self] fix in self?.locationChanged(fix) }
        location.onAccess = { [weak self] granted in self?.accessChanged(granted) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.themeChanged()
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(enteredForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(enteredBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        location.start()
    }

    /// The first moment the real dark/light setting is known, so the page is
    /// loaded here rather than in viewDidLoad: its first frame is already right.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if !loaded { loadPage() }
    }

    private func loadPage() {
        loaded = true
        webReady = false
        themeShown = theme
        let scripts = webView.configuration.userContentController
        scripts.removeAllUserScripts()
        scripts.addUserScript(Bridge.userScript(theme: themeShown))
        webView.loadFileURL(assets.appendingPathComponent("globe.html"), allowingReadAccessTo: assets)
    }

    // MARK: - Page → native

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let value = body["value"] as? String
        switch type {
        case "ready":
            pageReady()
        case "requestTle":
            if let value { fetchTle(value) }
        case "openUrl":
            if let value, let url = URL(string: value), ["https", "http"].contains(url.scheme) {
                UIApplication.shared.open(url)
            }
        case "log":
            log.debug("\(value ?? "", privacy: .public)")
        default:
            break
        }
    }

    private func pageReady() {
        webReady = true
        if theme != themeShown { themeChanged() }
        if let lastFix { pushLocation(lastFix) }
        if locationDenied { push("onPermission", [false]) }
    }

    private func fetchTle(_ group: String) {
        Task {
            let result = await tle.tle(for: group)
            push("onTle", [group, result.text, result.source])
        }
    }

    // MARK: - Native → page

    private func themeChanged() {
        guard webReady, theme != themeShown else { return }
        themeShown = theme
        webView.evaluateJavaScript("window.__orbitTheme = '\(themeShown)';", completionHandler: nil)
        push("onTheme", [themeShown])
    }

    private func locationChanged(_ fix: CLLocation) {
        lastFix = fix
        if webReady { pushLocation(fix) }
    }

    private func pushLocation(_ fix: CLLocation) {
        let altitude = fix.verticalAccuracy >= 0 ? fix.altitude : 0
        push("onLocation", [fix.coordinate.latitude, fix.coordinate.longitude, altitude])
    }

    private func accessChanged(_ granted: Bool) {
        locationDenied = !granted
        if webReady && !granted { push("onPermission", [false]) }
    }

    private func push(_ function: String, _ args: [Any]) {
        guard let js = Bridge.call(function, args) else { return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Lifecycle

    @objc private func enteredForeground() { location.start() }
    @objc private func enteredBackground() { location.stop() }

    /// iOS may end a backgrounded page's process to free memory (WebGL makes
    /// it a big one). Coming back to a blank screen is worse than a reload.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage()
    }

    /// The page only ever shows itself; any other link opens outside the app.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, !url.isFileURL else { return decisionHandler(.allow) }
        if ["https", "http"].contains(url.scheme) { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }
}
