import WebKit

/// `window.Android` as the page knows it from the Android app — the same
/// method names, so globe.js runs unchanged on both phones.
///
/// Android's JavascriptInterface calls are synchronous and can return values;
/// WebKit's message handlers are one-way. The only values the page reads back
/// are the theme and the capabilities, so those are kept in the page by
/// native (`window.__orbitTheme`) and everything else becomes a message.
@MainActor
enum Bridge {
    static let handlerName = "orbit"

    /// Injected before the page's own first script runs, so the `<head>`
    /// theme check already finds it.
    static func userScript(theme: String) -> WKUserScript {
        let source = """
        (function () {
          window.__orbitTheme = '\(theme)';
          function post(type, value) {
            window.webkit.messageHandlers.\(handlerName).postMessage(
              { type: type, value: value === undefined ? null : String(value) });
          }
          function nothing() {}
          window.Android = {
            ready: function () { post('ready'); },
            requestTle: function (group) { post('requestTle', group); },
            openUrl: function (url) { post('openUrl', url); },
            log: function (msg) { post('log', msg); },
            theme: function () { return window.__orbitTheme; },
            capabilities: function () { return '{"gnss":false,"selfUpdate":false}'; },
            updateCheck: nothing, updateDownload: nothing, updateGrantInstall: nothing,
            updateCancel: nothing, updateDismiss: nothing, updateSetAuto: nothing
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// `window.SatBridge.<function>(args…)`, with the arguments JSON-encoded
    /// so no satellite name or TLE line can break out of its string.
    /// Nil for anything JSON can't hold (a NaN would otherwise raise, not throw).
    static func call(_ function: String, _ args: [Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.SatBridge && window.SatBridge.\(function).apply(null, \(json));"
    }
}

/// WKUserContentController holds its handlers strongly, and the controller
/// holds the web view; this breaks that loop.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
