# Changelog

Every release of Orbit (SatelliteTracker), newest first. Versions are MAJOR.MINOR.PATCH — MAJOR
when something people rely on changes or goes away, MINOR for something new,
PATCH for a fix — and each is a git tag (`vX.Y.Z`) on the commit that
shipped. `tools/release` in Claudes Projects writes these entries.

## 2.0.4 — 2026-11-04

Coastlines stay sharp and smooth when you zoom all the way in

- Smooth coastlines when zoomed in: the Earth's shader paints the grey map
- iOS: smooth coastlines close up — the shader paints the grey Earth map
- iOS 2.2.0: picking a satellite in search flies in close to it
- iOS 2.1.0: navigation satellites above you glow, with beams down to you
- iOS: run-on-iphone finds a phone whose tunnel is not up yet
- iOS: App Store notes — iPad and iPhone Duo checked, screenshot launch variables, Xcode 27.1
- iOS: on its side, the card stands beside the globe
- iOS: facts wrap instead of shrinking, and line up at the top
- iOS: the closed iPhone Duo — a short card, and a globe beside the side bar
- iOS: the globe makes room for a bar down the side as well as the card
- iOS: the card floats beside the globe on iPad
- iOS: privacy manifests and in-app policy links for the App Store

## 2.0.3 — 2026-10-22

A new icon: a ringed planet with its satellite, in the same flat violet as the other n3d apps

- New icon: the ringed planet, in the family's flat violet
- iOS: fix what the review of the native rewrite found
- iOS: rewrite Orbit natively — Metal globe, Liquid Glass, Swift SGP4
- iOS: read Celestrak's CRLF lines, so live orbits are used
- Add an iPhone version of Orbit (ios/)

## 2.0.2 — 2026-10-06

Buttons, the update bar and switches are one flat violet, matching the n3d sites

- Filled controls: one flat violet, no gradient

## 2.0.1 — 2026-09-24

A thin, calm ring marks the satellite you tapped, instead of the thick violet band

- Make the selection ring a thin ring just outside the dot

## 2.0.0 — 2026-09-24

Neumorphic redesign in the n3d style, light and dark following the phone; satellites tap where they are drawn, at any zoom; the satellites your phone is using glow on their own dots

- Fix what the review of the redesign found
- Redesign Orbit in the n3d neumorphic style; fix satellite tap targets
- Add the MIT license ahead of going public
- Add a changelog; versions start at v1.2.0
- Keep the Gradle settings Android Studio added

## 1.2.0 — 2026-09-19 · versionCode 3

As published on n3d-store.com/apps (the app shows it as "1.2.0"). The About
sheet can now check n3d-store.com for a new version and install it itself, so
an update no longer means going back to the website.

Versions start here; everything earlier is in `git log`.
