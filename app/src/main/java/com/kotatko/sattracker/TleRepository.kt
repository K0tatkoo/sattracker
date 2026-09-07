package com.kotatko.sattracker

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Fetches real Two-Line-Element (TLE) orbital data from Celestrak for a given catalog "group"
 * (e.g. "starlink", "stations", "gps-ops"). Results are cached on disk; if the network fails and
 * no cache exists, a per-group bundled snapshot in assets is used (never a generic one, so a
 * category never shows satellites that don't belong to it).
 *
 * getTle also reports where the data came from (live / cache / offline / none) so the UI can tell
 * the user when it's showing offline data.
 */
class TleRepository(private val context: Context) {

    data class TleResult(val text: String, val source: String)

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)   // per-read inactivity
        .callTimeout(90, TimeUnit.SECONDS)   // whole-call ceiling (large downloads like Starlink)
        .build()

    suspend fun getTle(group: String): TleResult = withContext(Dispatchers.IO) {
        val cacheFile = File(context.cacheDir, "tle_${sanitize(group)}.txt")
        val fresh = cacheFile.exists() &&
            (System.currentTimeMillis() - cacheFile.lastModified()) < CACHE_TTL_MS
        if (fresh) return@withContext TleResult(cap(cacheFile.readText()), "cache")

        val downloaded = runCatching { download(group) }.getOrNull()
        if (!downloaded.isNullOrBlank() && looksLikeTle(downloaded)) {
            runCatching { cacheFile.writeText(downloaded) }
            return@withContext TleResult(cap(downloaded), "live")
        }

        if (cacheFile.exists()) return@withContext TleResult(cap(cacheFile.readText()), "cache")

        val bundled = runCatching {
            context.assets.open("tle/$group.txt").bufferedReader().use { it.readText() }
        }.getOrNull()
        if (!bundled.isNullOrBlank()) return@withContext TleResult(cap(bundled), "offline")

        TleResult("", "none")
    }

    private fun download(group: String): String {
        val url = "https://celestrak.org/NORAD/elements/gp.php?GROUP=$group&FORMAT=tle"
        repeat(2) {
            try {
                val req = Request.Builder()
                    .url(url)
                    .header("User-Agent", "OrbitSatTracker/1.0 (Android)")
                    .build()
                client.newCall(req).execute().use { resp ->
                    if (resp.isSuccessful) {
                        val body = resp.body?.string().orEmpty()
                        if (body.isNotBlank()) return body
                    }
                }
            } catch (_: Exception) { /* retry once */ }
        }
        return ""
    }

    /** Keep only the first [maxSats] satellites so we never ship a 1.8 MB payload into the WebView. */
    private fun cap(text: String, maxSats: Int = 400): String {
        val lines = text.split("\n")
        return if (lines.size <= maxSats * 3) text else lines.take(maxSats * 3).joinToString("\n")
    }

    private fun looksLikeTle(s: String): Boolean {
        var l1 = false; var l2 = false
        for (line in s.lineSequence()) {
            if (line.startsWith("1 ") && line.length > 60) l1 = true
            else if (line.startsWith("2 ") && line.length > 60) l2 = true
            if (l1 && l2) return true
        }
        return false
    }

    private fun sanitize(s: String) = s.replace(Regex("[^A-Za-z0-9_-]"), "_")

    companion object {
        private val CACHE_TTL_MS = TimeUnit.HOURS.toMillis(3)
    }
}
