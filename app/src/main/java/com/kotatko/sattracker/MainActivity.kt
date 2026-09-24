package com.kotatko.sattracker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.webkit.WebView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.kotatko.sattracker.databinding.ActivityMainBinding
import com.kotatko.sattracker.update.Release
import com.kotatko.sattracker.update.UpdateError
import com.kotatko.sattracker.update.UpdateManager
import com.kotatko.sattracker.update.UpdateState
import kotlinx.coroutines.launch
import org.json.JSONObject

class MainActivity : AppCompatActivity(), WebAppInterface.Host {

    private lateinit var binding: ActivityMainBinding
    private lateinit var gnss: GnssTracker
    private lateinit var gnssRaw: GnssRawTracker
    private lateinit var location: LocationProvider
    private lateinit var tleRepo: TleRepository

    /** The app looking after its own version. See update/Updater.kt. */
    private val updates by lazy { UpdateManager(this) }

    private var webReady = false
    private var darkNow = false
    private var lastLat: Double? = null
    private var lastLon: Double? = null
    private var lastAlt: Double = 0.0

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        val granted = result[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            result[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        if (granted) startLocationServices()
        pushToJs("window.SatBridge && window.SatBridge.onPermission(${granted})")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        darkNow = isDark(resources.configuration)
        applySystemBars(darkNow)

        tleRepo = TleRepository(this)
        gnss = GnssTracker(this) { json ->
            runOnUiThread { pushToJs("window.SatBridge && window.SatBridge.onGnss(${JSONObject.quote(json)})") }
        }
        gnssRaw = GnssRawTracker(this) { json ->
            runOnUiThread { pushToJs("window.SatBridge && window.SatBridge.onMeasurements(${JSONObject.quote(json)})") }
        }
        location = LocationProvider(this) { lat, lon, alt ->
            lastLat = lat; lastLon = lon; lastAlt = alt
            runOnUiThread { pushToJs("window.SatBridge && window.SatBridge.onLocation($lat,$lon,$alt)") }
        }

        setupWebView()
        requestLocationPermission()

        // Every change of update state is pushed straight into the sheet, so
        // the JS never keeps a copy it could get wrong.
        lifecycleScope.launch {
            updates.state.collect { if (webReady) pushUpdateState(it) }
        }
        updates.checkOnLaunch()
    }

    private fun setupWebView() {
        val wv = binding.webView
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        wv.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            cacheMode = android.webkit.WebSettings.LOAD_DEFAULT
            // Allow the local file:// page to load local file:// assets (e.g. the Earth texture)
            // as WebGL textures without being blocked as cross-origin.
            allowFileAccess = true
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = true
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = true
        }
        wv.addJavascriptInterface(WebAppInterface(this), "Android")
        wv.loadUrl("file:///android_asset/globe.html")
    }

    private fun requestLocationPermission() {
        val hasFine = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (hasFine) {
            startLocationServices()
        } else {
            permissionLauncher.launch(
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                )
            )
        }
    }

    private fun startLocationServices() {
        gnss.start()
        gnssRaw.start()
        location.start()
    }

    // ---- WebAppInterface.Host ----

    override fun onWebReady() {
        webReady = true
        runOnUiThread {
            lastLat?.let { pushToJs("window.SatBridge && window.SatBridge.onLocation($it,${lastLon},${lastAlt})") }
            pushUpdateState(updates.state.value)
        }
    }

    override fun requestTle(group: String) {
        lifecycleScope.launch {
            val res = tleRepo.getTle(group)
            pushToJs(
                "window.SatBridge && window.SatBridge.onTle(" +
                    "${JSONObject.quote(group)},${JSONObject.quote(res.text)},${JSONObject.quote(res.source)})"
            )
        }
    }

    override fun openUrl(url: String) {
        runOnUiThread {
            runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
        }
    }

    override fun log(msg: String) {
        Log.d("SatWeb", msg)
    }

    override fun themeName(): String = if (isDark(resources.configuration)) "dark" else "light"

    // ---- theme ----------------------------------------------------------------
    // The manifest handles uiMode itself, so flipping the phone's dark mode does
    // not recreate the activity (which would reload the page and drop every
    // loaded satellite); the page is told instead and repaints in place.

    private fun isDark(config: Configuration) =
        (config.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val dark = isDark(newConfig)
        if (dark == darkNow) return
        darkNow = dark
        applySystemBars(dark)
        pushToJs("window.SatBridge && window.SatBridge.onTheme('${if (dark) "dark" else "light"}')")
    }

    /**
     * Paint everything behind the page in the page's own surface colour, and
     * give the status and navigation bars icons that read on it: light icons on
     * the dark theme, dark ones on the light theme.
     */
    private fun applySystemBars(dark: Boolean) {
        val bg = ContextCompat.getColor(this, R.color.bg)
        @Suppress("DEPRECATION")
        run {
            // Ignored from Android 15, where the page itself draws behind the bars.
            window.statusBarColor = bg
            window.navigationBarColor = bg
        }
        binding.root.setBackgroundColor(bg)
        binding.webView.setBackgroundColor(bg)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !dark
        }
    }

    // ---- updates ------------------------------------------------------------

    override fun updateCheck() = updates.check()

    override fun updateDownload() {
        (updates.state.value as? UpdateState.Available)?.let { updates.download(it.release) }
    }

    override fun updateGrantInstall() {
        runOnUiThread { runCatching { startActivity(updates.unknownSourcesIntent()) } }
    }

    override fun updateCancel() = updates.cancel()

    override fun updateDismiss() = updates.dismiss()

    override fun updateSetAuto(on: Boolean) {
        updates.autoCheck = on
        pushUpdateState(updates.state.value)
    }

    /**
     * The whole update state as one object, because the sheet redraws from
     * scratch every time rather than patching itself.
     *
     * `phase` is the discriminator and everything else is optional detail for
     * the phase it belongs to — so adding a phase later cannot break an
     * existing branch.
     */
    private fun pushUpdateState(state: UpdateState) {
        val json = JSONObject()
            .put("installed", updates.installedVersionName)
            .put("canSelfUpdate", updates.canSelfUpdate)
            .put("auto", updates.autoCheck)
        when (state) {
            is UpdateState.Idle -> json.put("phase", "idle")
            is UpdateState.Checking -> json.put("phase", "checking")
            is UpdateState.UpToDate -> json.put("phase", "current")
            is UpdateState.Available -> json.put("phase", "available").release(state.release)
            is UpdateState.Downloading -> json.put("phase", "downloading").release(state.release)
                .put("bytes", state.bytes).put("total", state.total)
            is UpdateState.Ready -> json.put("phase", "allow").release(state.release)
            is UpdateState.Installing -> json.put("phase", "installing").release(state.release)
            is UpdateState.Failed -> json.put("phase", "failed")
                .put("error", message(state.error))
                .put("detail", state.detail ?: JSONObject.NULL)
        }
        runOnUiThread {
            pushToJs("window.SatBridge && window.SatBridge.onUpdate(${JSONObject.quote(json.toString())})")
        }
    }

    private fun JSONObject.release(release: Release): JSONObject = this
        .put("version", release.versionName)
        .put("size", release.sizeBytes)
        .put("notes", release.notes ?: JSONObject.NULL)

    private fun message(error: UpdateError): String = when (error) {
        UpdateError.Network -> "Could not reach n3d-store.com. Check your connection and try again."
        UpdateError.Server -> "The store answered with something unusable. Try again later."
        UpdateError.Checksum ->
            "The download did not match what the store published, so it was thrown away. " +
                "Nothing was installed."
        UpdateError.Signature ->
            "That file is signed by a different key and can never replace this app. " +
                "Nothing was installed."
        UpdateError.Package -> "That file is a different app. Nothing was installed."
        UpdateError.TooOld -> "The new version needs a newer Android than this phone runs."
        UpdateError.Storage -> "Not enough room to download the update."
        UpdateError.Install -> "Android refused the install."
    }

    private fun pushToJs(js: String) {
        binding.webView.evaluateJavascript(js, null)
    }

    // ---- Lifecycle ----

    override fun onResume() {
        super.onResume()
        binding.webView.onResume()
        // Nothing reports the "install unknown apps" switch being flipped, so
        // an already-downloaded update is picked back up on the way back in.
        updates.resumeInstall()
        gnss.start()
        gnssRaw.start()
        location.start()
    }

    override fun onPause() {
        binding.webView.onPause()
        gnss.stop()
        gnssRaw.stop()
        location.stop()
        super.onPause()
    }

    override fun onDestroy() {
        binding.webView.destroy()
        super.onDestroy()
    }
}
