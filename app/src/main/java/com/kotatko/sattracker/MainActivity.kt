package com.kotatko.sattracker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.webkit.WebView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.kotatko.sattracker.databinding.ActivityMainBinding
import kotlinx.coroutines.launch
import org.json.JSONObject

class MainActivity : AppCompatActivity(), WebAppInterface.Host {

    private lateinit var binding: ActivityMainBinding
    private lateinit var gnss: GnssTracker
    private lateinit var gnssRaw: GnssRawTracker
    private lateinit var location: LocationProvider
    private lateinit var tleRepo: TleRepository

    private var webReady = false
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

    private fun pushToJs(js: String) {
        binding.webView.evaluateJavascript(js, null)
    }

    // ---- Lifecycle ----

    override fun onResume() {
        super.onResume()
        binding.webView.onResume()
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
