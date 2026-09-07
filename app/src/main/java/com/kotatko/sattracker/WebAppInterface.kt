package com.kotatko.sattracker

import android.webkit.JavascriptInterface

/**
 * Bridge exposed to the WebView JavaScript as `window.Android`.
 * Every method here is callable from globe.js. Keep it small and side-effect-explicit.
 */
class WebAppInterface(private val host: Host) {

    interface Host {
        fun onWebReady()
        fun requestTle(group: String)
        fun openUrl(url: String)
        fun log(msg: String)
    }

    /** JS calls this once the globe UI has finished loading and is ready for data. */
    @JavascriptInterface
    fun ready() = host.onWebReady()

    /** JS asks native to (re)fetch a Celestrak group; native replies via SatBridge.onTle(). */
    @JavascriptInterface
    fun requestTle(group: String) = host.requestTle(group)

    /** Open an external link (e.g. a satellite's info page) in the browser. */
    @JavascriptInterface
    fun openUrl(url: String) = host.openUrl(url)

    @JavascriptInterface
    fun log(msg: String) = host.log(msg)
}
