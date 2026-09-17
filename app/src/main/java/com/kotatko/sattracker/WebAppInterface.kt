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

        // ---- updates. See update/Updater.kt; the sheet in globe.html is the UI. ----
        fun updateCheck()
        fun updateDownload()
        fun updateGrantInstall()
        fun updateCancel()
        fun updateDismiss()
        fun updateSetAuto(on: Boolean)
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

    /* ---- updates -----------------------------------------------------------
       The whole update cycle is driven from the About sheet. Every one of these
       is a request, not an action: native answers by pushing a fresh state
       object into SatBridge.onUpdate(), and the sheet redraws from that. So the
       JS never holds update state of its own and cannot get out of step with
       what the app is really doing. */

    /** Ask the store whether there is a newer version. */
    @JavascriptInterface
    fun updateCheck() = host.updateCheck()

    /** Download the version last reported as available, and verify it. */
    @JavascriptInterface
    fun updateDownload() = host.updateDownload()

    /** Open the system screen that allows this app to install packages. */
    @JavascriptInterface
    fun updateGrantInstall() = host.updateGrantInstall()

    @JavascriptInterface
    fun updateCancel() = host.updateCancel()

    /** Put the sheet back to its resting state without changing anything. */
    @JavascriptInterface
    fun updateDismiss() = host.updateDismiss()

    /** The "look for updates by itself" switch. */
    @JavascriptInterface
    fun updateSetAuto(on: Boolean) = host.updateSetAuto(on)
}
