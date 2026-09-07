package com.kotatko.sattracker

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Reads the live GNSS (GPS/Galileo/GLONASS/BeiDou/QZSS/…) satellite status from the
 * device's location chip — i.e. the satellites the phone is ACTUALLY using right now.
 * This is the genuine "satellite in use" data. Each update is emitted as a JSON string.
 */
class GnssTracker(
    private val context: Context,
    private val onUpdate: (String) -> Unit
) {
    private val locationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private var callback: GnssStatus.Callback? = null

    fun start() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) return
        if (callback != null) return

        val cb = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                emit(status)
            }
        }
        callback = cb
        try {
            locationManager.registerGnssStatusCallback(cb, handler)
        } catch (_: SecurityException) {
        }
    }

    fun stop() {
        callback?.let { locationManager.unregisterGnssStatusCallback(it) }
        callback = null
    }

    private fun emit(status: GnssStatus) {
        val sats = JSONArray()
        var usedCount = 0
        for (i in 0 until status.satelliteCount) {
            val used = status.usedInFix(i)
            if (used) usedCount++
            val o = JSONObject()
            o.put("constellation", constellationName(status.getConstellationType(i)))
            o.put("svid", status.getSvid(i))
            o.put("usedInFix", used)
            o.put("cn0", round1(status.getCn0DbHz(i)))
            o.put("azimuth", round1(status.getAzimuthDegrees(i)))
            o.put("elevation", round1(status.getElevationDegrees(i)))
            o.put("hasAlmanac", status.hasAlmanacData(i))
            o.put("hasEphemeris", status.hasEphemerisData(i))
            sats.put(o)
        }
        val payload = JSONObject()
        payload.put("total", status.satelliteCount)
        payload.put("used", usedCount)
        payload.put("sats", sats)
        onUpdate(payload.toString())
    }

    private fun round1(v: Float) = Math.round(v * 10f) / 10.0

    private fun constellationName(type: Int): String = when (type) {
        GnssStatus.CONSTELLATION_GPS -> "GPS"
        GnssStatus.CONSTELLATION_GLONASS -> "GLONASS"
        GnssStatus.CONSTELLATION_GALILEO -> "Galileo"
        GnssStatus.CONSTELLATION_BEIDOU -> "BeiDou"
        GnssStatus.CONSTELLATION_QZSS -> "QZSS"
        GnssStatus.CONSTELLATION_IRNSS -> "NavIC"
        GnssStatus.CONSTELLATION_SBAS -> "SBAS"
        else -> "Unknown"
    }
}
