# Changelog

Every release of Orbit (SatelliteTracker), newest first. Versions are MAJOR.MINOR.PATCH — MAJOR
when something people rely on changes or goes away, MINOR for something new,
PATCH for a fix — and each is a git tag (`vX.Y.Z`) on the commit that
shipped. `tools/release` in Claudes Projects writes these entries.

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
