# Orbit — Live Satellite Tracker (Android & iPhone)

A clean 3D globe showing **real satellites** orbiting Earth in real time, plus a live panel of
the **GNSS satellites your phone is actually using** right now, and **next-pass / next-rise
countdowns** for your location. Free, no ads, no in-app purchases, no accounts.

- **3D globe** — three.js (WebGL) inside a native WebView. Rotate/zoom with touch.
- **Real orbits** — Two-Line-Element (TLE) data from [Celestrak](https://celestrak.org), propagated
  on-device with SGP4 ([satellite.js](https://github.com/shashwatak/satellite-js)).
- **"Your phone is using"** — Android `GnssStatus` API, shown as a live sky-plot + count.
- **Tap a satellite** — country, operator, purpose, NORAD id, altitude, speed, sub-point,
  look-angle from you, and next pass. Taps go to whichever dot is nearest your finger, at any
  zoom; a satellite your phone is receiving is shown under its real name, glowing on its own dot.
- **The n3d look** — the same neumorphic light/dark design as the other n3d apps and sites,
  following the phone's dark-mode setting live.
- **Categories** — toggle GPS, GLONASS, Galileo, BeiDou, ISS/Stations, Starlink, Weather, Science.
- **No ads, no tracking** — the only servers it ever talks to are Celestrak, for orbital data,
  and n3d-store.com, to check for a new version. Your location is used on-device and never
  transmitted.

---

## 1. Open & run on your Galaxy S24 (over USB)

1. Install **Android Studio** (Ladybug or newer).
2. **File ▸ Open** → select this `SatelliteTracker` folder. Let Gradle sync (it downloads the
   Gradle wrapper, AGP, and dependencies automatically the first time).
3. On the S24: **Settings ▸ About phone ▸ Software information** → tap **Build number** 7×
   to enable Developer options. Then **Settings ▸ Developer options ▸ USB debugging: ON**.
4. Plug the phone in via cable, accept the "Allow USB debugging?" prompt on the phone.
5. In Android Studio pick your device in the toolbar and press **▶ Run**.

The debug build installs as a separate app id (`com.kotatko.sattracker.debug`), so it can sit
alongside the release build without either replacing the other.

From the command line instead:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
./gradlew assembleRelease
```

---

## 2. Distribution

The app is published as a **signed APK** at
<https://n3d-store.com/apps.html> and linked from the portfolio — not through the Play Store.
`assembleRelease` signs it with the shared n3d release key from
`~/.android/n3d-release.properties`; without that file the build still succeeds, just unsigned.

Nothing needs replacing before you build. There are no ad ids, no product ids and no API keys
anywhere in the project.

---

## 3. The app updates itself (v1.2.0)

Orbit is not on Play, so nothing would otherwise tell anybody a new version exists. Since 1.2.0
the About sheet carries an Updates block that asks `n3d-store.com/api/apps/orbit/update` what the
newest build is, downloads `/apk/orbit.apk` if it is newer, checks it against the SHA-256 the
store published and against this app's own signing certificate, and hands it to Android's package
installer — which still shows its own confirmation.

`update/Updater.kt` is the whole of it and is the same file in all five published apps, differing
only in the slug and package name. `MainActivity` pushes every state change into the sheet through
`SatBridge.onUpdate()`, so the JavaScript holds no update state of its own.

It also looks by itself, at most once a day, silently — no spinner and no error if the phone is
offline. That is switchable in the sheet.

## 4. Ads and in-app purchases were removed (v1.1.0)

Up to v1.0.0 this app carried an AdMob banner and a one-time "remove ads" Play Billing purchase,
both wired up with Google's **sample/test** ids. Both were taken out completely in v1.1.0, because
neither can work outside the Play Store: sideloaded, the banner would only ever have shown test
ads and the purchase button could not have completed at all.

What went, so nothing here is half-removed:

| Removed | Where |
|---|---|
| `play-services-ads`, `billing-ktx` dependencies | `app/build.gradle.kts` |
| `BillingManager.kt` | deleted |
| `SatApp.kt` (existed only to call `MobileAds.initialize`) | deleted, and `android:name` dropped from the manifest |
| `AdView` field, `setupAds()`, `adaptiveBannerSize()`, `applyProState()`, ad lifecycle calls | `MainActivity.kt` |
| `buyPro()` / `restorePurchases()` | `WebAppInterface.kt` (both sides of the bridge) |
| `com.google.android.gms.permission.AD_ID`, the AdMob `<meta-data>`, `admobAppId` placeholder | `AndroidManifest.xml` / `build.gradle.kts` |
| `admob_banner_unit_id`, `pro_product_id` | `strings.xml` |
| `adContainer` banner slot | `activity_main.xml`, now a plain `FrameLayout` around the WebView |
| "Remove ads" button, purchase sheet, `state.isPro`, `SatBridge.onPro` | `globe.html` / `globe.js` |

One thing deliberately kept: the CSS class `.btn.pro` was doing double duty as the lit state of the
GNSS and log toggles, so it was **renamed to `.btn.active`** rather than deleted — deleting it would
have silently killed the highlight on two buttons that have nothing to do with ads.

The settings sheet, which used to be the purchase sheet, is now a short About panel with the data
attribution in it.

---

## 5. If you ever do publish it to Play

- Build a signed **App Bundle** (*Build ▸ Generate Signed Bundle / APK*) rather than an APK.
- Host a privacy policy URL — mandatory because the app requests location. `PRIVACY_POLICY.md`
  is a filled-in starting point.
- Complete the **Data safety** form: *Location*, used on-device, not shared, not collected.
- Content rating, category (*Tools* or *Education*), screenshots, feature graphic, icon.
- The app no longer uses an advertising id, so that whole branch of the questionnaire is a "no".

---

## 6. Architecture

```
WebView (assets/globe.html · globe.js · styles.css)   ← 3D globe + all UI, orbit math (SGP4)
        ▲  window.SatBridge.*            window.Android.*  ▼
MainActivity (Kotlin)
 ├─ GnssTracker        → live "satellites in use" (GnssStatus)
 ├─ LocationProvider   → observer lat/lon (FusedLocation)
 └─ TleRepository      → Celestrak TLE fetch + disk cache + assets fallback
```

- **three.js, OrbitControls, satellite.js and the Earth texture are bundled locally** in
  `assets/lib/` and loaded as plain `<script>` tags — no CDN, no ES-module import map. This is
  required so the app loads correctly from `file:///android_asset` and works fully offline.
  (An earlier version loaded these from a CDN as ES modules; that fails in a real WebView loaded
  from `file://`, leaving the app stuck on the loading screen.)
- A watchdog in `globe.html` force-clears the loading overlay after 12 s and surfaces any script
  error, so the app can never hang silently on boot.
- TLE data is cached for 3 h (`TleRepository.CACHE_TTL_MS`) to respect Celestrak's fair-use policy.
  On first launch with no network, the app falls back to the bundled snapshots in `assets/tle/`.

## 7. Data sources & attribution

- Orbital elements: **Celestrak** (T.S. Kelso). Please keep within their access policy.
- Propagation: **satellite.js** (MIT). Rendering: **three.js** (MIT).
- Satellite metadata (country/operator/purpose) is a curated best-effort map in `globe.js`
  (`resolveMeta`). For richer data, integrate the **Celestrak SATCAT** or **UCS Satellite Database**.

## 8. Known limitations / next steps

- GNSS "in use" satellites can't be matched 1:1 to catalog objects (PRN vs NORAD id), so they're
  shown in their own sky-plot rather than highlighted on the 3D globe. This is technically correct.
- Starlink is capped (see `CATEGORIES[].cap` in `globe.js`) to keep the globe readable and fast.
- Regular phones (incl. the S24) don't route calls/data through comms satellites, so only
  positioning (GNSS) satellites are genuinely "in use." Everything else is tracked/visualized.

## 9. iPhone version (`ios/`)

A native app since iPhone 2.0.0 (before that, 1.0.0 was this same page in a Swift shell). Same
satellites, same colours, same numbers; iPhone-native everywhere else.

- **The globe** is drawn with Metal (`ios/Orbit/Render`): the page's three.js scene redrawn
  piece for piece — the palette-repainted Earth under a lamp fixed top-left, the raised-globe
  shadow pair, graticule, atmosphere and stars on the dark theme, fixed-size dots, the thin
  selection ring, the selected satellite's orbit. Taps pick in screen space, as on Android. On a
  phone held upright the camera starts far enough back that the whole Earth fits.
- **The chrome** is SwiftUI in Liquid Glass (iOS 26+): glass toolbar, category chips, and the
  satellite's card as a floating glass sheet that leaves the globe usable (the Earth glides up
  out of its way). Follows the phone's light/dark setting live.
- **The orbits** come from `ios/OrbitCore`, a Swift package: satellite.js 5.0.0's SGP4 ported
  line for line, plus the page's look angles and passes. It is checked against satellite.js
  itself — `node ios/tools/sgp4-fixtures.mjs` runs the bundled `satellite.min.js` (and the
  page's own `nextRise`/`nextPass`) over near-Earth, GNSS, geostationary and Molniya orbits,
  and `swift test` in `ios/OrbitCore` compares: positions agree to 10⁻¹⁰ km and every pass to
  the millisecond. The Earth map and the offline TLEs are this app's own files, used in place.
- **iPhone only:** search every category (and Celestrak itself) by name or NORAD number and fly
  to the result; **pass alerts** (local notifications, planned two days ahead, optionally only
  passes you can see: satellite sunlit, your sky dark); a **Next ISS pass** widget for the Home
  and Lock Screens; a 24-hour pass list on the card; Follow keeps a satellite in front of you.

Two Android features are missing because iOS gives them to no app: the satellites your phone
is using (no `GnssStatus` or raw measurements), and updating itself (only the App Store or
TestFlight can replace an iPhone app).

Build and run (needs Xcode, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) only when
`project.yml` changes; Xcode 26+ also asks for its Metal toolchain once,
`xcodebuild -downloadComponent MetalToolchain`):

```bash
cd ios && xcodegen          # regenerate Orbit.xcodeproj after editing project.yml
open Orbit.xcodeproj        # then pick an iPhone simulator and press ▶ Run
cd ios/OrbitCore && swift test   # the orbit engine against satellite.js
```

On a real iPhone, `ios/tools/run-on-iphone.sh` builds and installs it. A free Apple ID works
but the app stops opening after 7 days until it is run again; the paid developer program removes
that limit. The app and its widget share an App Group (`group.com.kotatko.sattracker`); with a
free Apple ID it has to be added once in Xcode's Signing & Capabilities on both targets.

## License

MIT — see [LICENSE](LICENSE). Built by Danny ([K0tatkoo](https://github.com/K0tatkoo)); installable builds are on [n3d-store.com/apps](https://n3d-store.com/apps.html).
