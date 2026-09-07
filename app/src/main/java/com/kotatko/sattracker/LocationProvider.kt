package com.kotatko.sattracker

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationResult
import android.os.Looper

/** Supplies the observer's lat/lon/alt so the globe can center on you and compute passes. */
class LocationProvider(
    private val context: Context,
    private val onLocation: (lat: Double, lon: Double, altMeters: Double) -> Unit
) {
    private val client = LocationServices.getFusedLocationProviderClient(context)
    private var callback: LocationCallback? = null

    private fun hasPermission() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    fun start() {
        if (!hasPermission() || callback != null) return

        // One immediate best-effort fix so the map centers quickly…
        try {
            client.lastLocation.addOnSuccessListener { loc ->
                if (loc != null) onLocation(loc.latitude, loc.longitude, loc.altitude)
            }
        } catch (_: SecurityException) {
        }

        // …then HIGH-ACCURACY updates. This is important beyond the map dot: requesting GPS-grade
        // location powers on the GNSS engine, which is what makes the "your phone is using"
        // satellite status (GnssStatus) actually report data.
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 5_000L)
            .setMinUpdateIntervalMillis(3_000L)
            .build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let { onLocation(it.latitude, it.longitude, it.altitude) }
            }
        }
        callback = cb
        try {
            client.requestLocationUpdates(request, cb, Looper.getMainLooper())
        } catch (_: SecurityException) {
        }
    }

    fun stop() {
        callback?.let { client.removeLocationUpdates(it) }
        callback = null
    }
}
