# Privacy Policy — Orbit (Live Satellite Tracker)

_Last updated: 7 September 2026. Publisher: Danny (Nebula 3D). Contact: n3d.store.official@gmail.com._

Orbit collects nothing, has no accounts, shows no ads, and contains no analytics or tracking of
any kind. This policy describes what the app actually does with data on your device.

## What stays on your device

- **Location.** With your permission, the app reads your device location to (a) centre the globe
  on you, (b) work out which GNSS satellites are above your horizon, and (c) calculate satellite
  passes over you. **Your location is processed entirely on the device and is never transmitted
  anywhere by this app.**
- **GNSS satellite status.** Read on-device to display the positioning satellites your phone is
  using, as a live count and sky-plot. Not transmitted.
- **Cached orbital data.** Downloaded orbital elements are cached in the app's private storage so
  the app works offline and to stay within Celestrak's fair-use policy. Clearing the app's data
  removes them.
- **No accounts, no profiles.** No sign-in, and no collection of your name, email, contacts,
  photos or advertising identifier.

## The two servers it talks to

**Celestrak** (celestrak.org) — public satellite orbital data (TLE sets). Ordinary web requests
for public files: they carry no identity and no location, and nothing about you is sent with them.
Celestrak will see the request the way any website sees a visitor, including your IP address.
Their policies are at <https://celestrak.org>.

**n3d-store.com** — where the app was downloaded from, and, since version 1.2.0, where it checks
for its own updates. The request asks one question — what is the newest version — and sends
nothing but the app's name and version in the User-Agent header. If a newer version exists and you
choose to install it, the APK is fetched from the same site. The check runs at most once a day and
you can switch it off in the About sheet, after which nothing but a button you press yourself
will ever make it.

That is the complete list. There is no analytics endpoint and no third-party SDK that phones
home.

## No advertising, no purchases

Versions up to 1.0.0 included a Google AdMob banner and a one-time "remove ads" purchase through
Google Play Billing. **Both were removed completely in version 1.1.0.** The app no longer contains
the AdMob or Play Billing libraries, requests no advertising identifier, and holds no
`com.google.android.gms.permission.AD_ID` permission. There is nothing to buy.

## Permissions

| Permission | Why | Optional? |
|---|---|---|
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | Centre the globe on you, GNSS sky-plot, pass predictions | Yes — deny it and everything else still works |
| `INTERNET` / `ACCESS_NETWORK_STATE` | Fetch orbital data from Celestrak, and check n3d-store.com for a new version of the app | Without it the app falls back to the orbital snapshots bundled in the APK |
| `REQUEST_INSTALL_PACKAGES` | Install an update the app downloaded for itself | Yes — Android also asks you to confirm every install, and will not even show that prompt until you switch Orbit on under "Install unknown apps" |

## Your choices

Deny or revoke location at any time in Android Settings; the GNSS panel and pass predictions
simply switch off and the rest of the app is unaffected. Turn off "Check by itself" in the About
sheet and the app will never contact n3d-store.com unless you press the button yourself.
Uninstalling removes every cached file.

## Children

The app is not directed at children under 13 and does not knowingly collect their data — it does
not collect anyone's data.

## Changes

Material changes to this policy will be reflected here with a new date.

## Contact

n3d.store.official@gmail.com
