package com.kotatko.sattracker

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.GnssMeasurementsEvent
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Streams the RAW GNSS signal measurements the phone receives from navigation satellites — the
 * closest thing to "live packet data from the satellites". Each ~1 Hz event carries, per satellite:
 * carrier-to-noise density (C/N0), pseudorange rate, accumulated delta range and carrier frequency.
 *
 * Requires ACCESS_FINE_LOCATION and a device that supports GNSS measurements (most modern phones,
 * including the Galaxy S24). If unsupported, no events arrive and the log simply stays quiet.
 */
class GnssRawTracker(
    private val context: Context,
    private val onData: (String) -> Unit
) {
    private val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private var cb: GnssMeasurementsEvent.Callback? = null

    fun start() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) return
        if (cb != null) return
        val c = object : GnssMeasurementsEvent.Callback() {
            override fun onGnssMeasurementsReceived(event: GnssMeasurementsEvent) = emit(event)
        }
        cb = c
        try { lm.registerGnssMeasurementsCallback(c, handler) } catch (_: SecurityException) {}
    }

    fun stop() {
        cb?.let { lm.unregisterGnssMeasurementsCallback(it) }
        cb = null
    }

    private fun emit(event: GnssMeasurementsEvent) {
        val arr = JSONArray()
        var n = 0
        for (m in event.measurements) {
            if (n >= 24) break
            val o = JSONObject()
            o.put("constellation", constName(m.constellationType))
            o.put("svid", m.svid)
            o.put("cn0", round1(m.cn0DbHz))
            o.put("prr", round1(m.pseudorangeRateMetersPerSecond))
            o.put("adr", round1(m.accumulatedDeltaRangeMeters))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && m.hasCarrierFrequencyHz()) {
                o.put("freqMHz", round2(m.carrierFrequencyHz.toDouble() / 1e6))
            }
            arr.put(o); n++
        }
        if (arr.length() == 0) return
        val payload = JSONObject()
        payload.put("t", System.currentTimeMillis())
        payload.put("m", arr)
        onData(payload.toString())
    }

    private fun round1(v: Double) = Math.round(v * 10.0) / 10.0
    private fun round2(v: Double) = Math.round(v * 100.0) / 100.0

    private fun constName(type: Int): String = when (type) {
        GnssStatus.CONSTELLATION_GPS -> "GPS"
        GnssStatus.CONSTELLATION_GLONASS -> "GLONASS"
        GnssStatus.CONSTELLATION_GALILEO -> "Galileo"
        GnssStatus.CONSTELLATION_BEIDOU -> "BeiDou"
        GnssStatus.CONSTELLATION_QZSS -> "QZSS"
        GnssStatus.CONSTELLATION_IRNSS -> "NavIC"
        GnssStatus.CONSTELLATION_SBAS -> "SBAS"
        else -> "?"
    }
}
