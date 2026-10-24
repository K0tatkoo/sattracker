# Orbit on the App Store

What Apple asks for, what is already in the app, and what is still to do
before the first submission. Written 2026-10-24 against App Review
Guidelines as they stood then — re-read the guidelines before submitting.

## Already in the app

| Requirement | Where |
|---|---|
| Privacy policy reachable in the app (5.1.1) | About › Privacy policy |
| Support link | About › Support |
| No other mobile platform named in the app (2.3.10) | the About sheet's old "Orbit for Android" link is gone |
| Privacy manifest | `Orbit/PrivacyInfo.xcprivacy` and `OrbitWidget/PrivacyInfo.xcprivacy`: no tracking, no data collected; required-reason APIs declared — UserDefaults `CA92.1` + `1C8F.1` (the App Group the widget shares), file timestamps `C617.1` (the TLE cache's age), system boot time `35F9.1` (frame timing) |
| Purpose strings | `NSLocationWhenInUseUsageDescription` for the app and the widget (`NSWidgetWantsLocation`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` — only HTTPS through URLSession, which is exempt |
| Launch screen, icons | `UILaunchScreen`; AppIcon 1024 px light/dark/tinted, opaque |

## App Store Connect answers

- **Privacy Policy URL:** https://n3d-store.com/orbit-privacy
- **Support URL:** https://n3d-store.com/app-support
- **App Privacy ("nutrition label"):** *Data Not Collected.* The location is
  used only on the device (Apple counts data as collected only when it is
  sent off the device where the developer or a partner can read it); the
  CeleStrak request carries nothing about the user.
- **Age rating:** every question "None" / "No" → 4+. (Links open in Safari;
  there is no in-app browser, so "unrestricted web access" is No.)
- **Category:** Education (secondary: Utilities).
- **Content rights:** orbital elements are CeleStrak's public data, credited
  in About.
- **Name / subtitle (30 characters each):** Orbit Satellite Tracker ·
  Live satellites on a 3D globe
- **Keywords (100 characters):**
  `satellite,tracker,iss,starlink,space station,pass,gps,globe,orbit,sgp4,tle,celestrak,sky,night`
- **Review notes:**
  > Orbit shows real satellites in real time on a 3D globe. No account is
  > needed. Location (while in use) is used only on the device to place the
  > user and compute passes; it is never transmitted. Orbital elements are
  > downloaded from celestrak.org. The "fetch" background mode and the
  > BGAppRefreshTask com.kotatko.sattracker.passes re-plan the local pass
  > notifications the user switched on (a bell on a satellite's card);
  > nothing is pushed from a server. The home-screen widget shows the next
  > ISS pass.
- **Screenshots:** 6.9" iPhone (1320 × 2868). The project also targets iPad
  (`TARGETED_DEVICE_FAMILY: "1,2"`), which makes 13" iPad screenshots
  (2064 × 2752) mandatory and means App Review may test on an iPad — check
  the globe, the card and every sheet in the iPad simulator first, or set the
  family to `"1"`.

## Before the first submission

1. **A paid Apple Developer Program membership** ($99/year). It needs the age
   of majority (18 in Czechia): wait, have a parent enrol, or enrol a company.
   An individual account shows the **legal full name** as the seller on the
   App Store; an organisation shows the company name (needs a D-U-N-S number).
2. **Register the App Group for real.** The free Personal Team cannot
   (`tools/NoAppGroup.entitlements` is the workaround); a paid team must
   register `group.com.kotatko.sattracker` on both targets, or the widget falls
   back to finding its own location and data.
3. Bump `CURRENT_PROJECT_VERSION` for every upload (App Store Connect refuses
   a build number it has seen).
