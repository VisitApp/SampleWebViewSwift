# Location Permission in the iOS WebView App

**Component:** `samplewebview` (SwiftUI + WKWebView container)
**Hosted web app:** Visit Health SSO (`niva-bupa-visit.getvisitapp.net`)
**Platforms:** iOS 26.1+ and macOS 26.0+ (built and verified). The target is also
configured for visionOS 26.1, but that SDK is not installed locally, so it has not been
built or tested.
**Date:** 11 August 2026

---

## 1. Purpose

This document describes how the native app grants the embedded web app access to the
device's location, specifically for the **Select Address → "Add as new address /
Current Location"** flow.

It is intended for the client's engineering and security reviewers.

---

## 2. Summary

The web app calls the standard W3C Geolocation API (`navigator.geolocation`). In a
plain `WKWebView` that call fails silently, because WebKit checks the *host app's*
CoreLocation authorization and does not present the iOS permission dialog on its own.
If the app has never been granted location access, the web page receives nothing.

To close that gap, the native app implements a **geolocation bridge**: it replaces
`navigator.geolocation` inside the web content with a shim that routes each request
through native CoreLocation. The native layer requests the iOS permission at the
moment it is needed and returns results in the exact shape the W3C API defines.

**Net effect for the web app: no changes required.** It continues to call
`navigator.geolocation` as it would in Safari, and now receives either coordinates or
a standard error code.

---

## 3. Why native work was required

| Behaviour | Plain WKWebView | With the bridge |
| --- | --- | --- |
| iOS location prompt shown when permission is undetermined | No | Yes |
| `getCurrentPosition` returns coordinates | Only if the app already had authorization | Yes |
| Web app receives a standard error code when denied | Inconsistent | Yes, W3C code `1` |
| User can recover from a previous "Don't Allow" | No path | Native alert deep-links to Settings |

---

## 4. Components

All files are in `samplewebview/`.

| File | Responsibility |
| --- | --- |
| `GeolocationBridge.swift` | Injects the JavaScript shim, receives requests from the web page, returns W3C-shaped responses |
| `LocationProvider.swift` | CoreLocation wrapper: requests authorization, acquires fixes, maps failures to W3C error codes |
| `WebViewModel.swift` | Installs the bridge on the `WKWebView`; raises the "open Settings" alert when permission was previously denied |
| `WebViewScreen.swift` | Presents that alert to the user |

### Request path

```
Web page: navigator.geolocation.getCurrentPosition(...)
   -> injected JS shim (WKUserScript, document start)
   -> WKScriptMessageHandlerWithReply  (returns a JS Promise)
   -> LocationProvider  -> CLLocationManager
   -> iOS permission dialog (only when status is "not determined")
   -> coordinates or error travel back down the same path
   -> web page success / error callback fires
```

---

## 5. Apple frameworks and APIs used

**CoreLocation**

- `CLLocationManager` — the location session
- `requestWhenInUseAuthorization()` — presents the iOS permission dialog
- `CLLocationManager.authorizationStatus` — current permission state
- `locationManagerDidChangeAuthorization(_:)` — observes the user's answer
- `startUpdatingLocation()` / `stopUpdatingLocation()` — acquires a fix, stopped as soon as no request is outstanding
- `desiredAccuracy` — set to `kCLLocationAccuracyBest` when the page passes `enableHighAccuracy: true`, otherwise `kCLLocationAccuracyHundredMeters`

**WebKit**

- `WKUserScript` — injects the shim at document start, in all frames
- `WKScriptMessageHandlerWithReply` — request/response channel; makes `postMessage` return a real JavaScript `Promise`
- `WKContentWorld.page` — the shim runs in the page's own JavaScript world so the web app sees the override
- `WKWebView.evaluateJavaScript(_:in:in:)` — delivers `watchPosition` updates

**SwiftUI / UIKit**

- `.alert` — the "Location Access Needed" recovery dialog
- `UIApplication.openSettingsURLString` — deep link to the app's privacy settings

---

## 6. Permission model

| Item | Value |
| --- | --- |
| Permission requested | Location, **When In Use** only |
| Background location | Not requested |
| Always-on / Always authorization | Not requested |
| When the prompt appears | Only when the web page actually asks for a location |
| Prompt on app launch | No |
| iOS purpose string | "Your location is used to fill in your current address." |

The permission is requested **lazily**. Opening the app, browsing, or signing in never
triggers the dialog. It appears the first time the web page calls
`navigator.geolocation` — in practice, when the user taps **Current Location** on the
Select Address screen.

---

## 7. User-facing behaviour

**First time (permission not yet decided)**

1. User taps "Add as new address / Current Location".
2. iOS shows the system dialog: *Allow "samplewebview" to use your location?* with
   **Allow Once**, **Allow While Using App**, **Don't Allow**.
3. On allow, the coordinates are handed to the web page and the address is filled in.
4. On "Don't Allow", the web page receives error code `1` and shows its own message.

**Permission already granted**

No dialog. The coordinates are returned directly.

**Permission previously denied**

iOS will not prompt again. The native app therefore shows its own alert —
**"Location Access Needed"** with **Open Settings** and **Not Now** — which deep-links
to the app's privacy settings so the user can re-enable access. The web page also
receives error code `1` so its own error state stays correct.

---

## 8. JavaScript API contract

Nothing in the web app needs to change. The shim implements the standard surface:

| API | Supported | Notes |
| --- | --- | --- |
| `navigator.geolocation.getCurrentPosition(success, error, options)` | Yes | |
| `navigator.geolocation.watchPosition(success, error, options)` | Yes | Backed by continuous native updates |
| `navigator.geolocation.clearWatch(id)` | Yes | Stops the native session when the last watcher is removed |
| `options.enableHighAccuracy` | Yes | Raises native accuracy |
| `options.timeout` | Yes | Milliseconds; returns error code `3` on expiry |
| `options.maximumAge` | Yes | A cached fix within the window is returned immediately |

**Success payload** matches `GeolocationPosition`:

```js
{
  coords: {
    latitude, longitude, accuracy,
    altitude, altitudeAccuracy,   // null when unavailable
    heading, speed                // null when unavailable
  },
  timestamp                        // milliseconds since epoch
}
```

**Error payload** matches `GeolocationPositionError`:

| Code | Meaning | Raised when |
| --- | --- | --- |
| `1` | `PERMISSION_DENIED` | User declined, or access is restricted by device policy |
| `2` | `POSITION_UNAVAILABLE` | CoreLocation could not produce a fix |
| `3` | `TIMEOUT` | The `timeout` option elapsed first |

Values that iOS reports as unavailable (altitude, heading, speed) are returned as
`null` rather than as CoreLocation's `-1` sentinel, per the W3C specification.

---

## 9. Project configuration

| Setting | Value | Reason |
| --- | --- | --- |
| `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` | "Your location is used to fill in your current address." | Required by iOS; the app terminates without it |
| `ENABLE_RESOURCE_ACCESS_LOCATION` | `YES` | macOS sandbox entitlement `com.apple.security.personal-information.location` |
| `ENABLE_OUTGOING_NETWORK_CONNECTIONS` | `YES` | macOS sandbox entitlement `com.apple.security.network.client` |

---

## 10. Data handling

- Location is requested only in direct response to a web page call.
- The native layer does not store coordinates on disk, log them, cache them beyond
  CoreLocation's own in-memory last-known value, or send them to any endpoint. It
  passes them only to the web content loaded in the WebView.
- Any onward transmission or storage is performed by the web application, under its
  own privacy policy.
- The native location session is stopped as soon as no request or watcher is
  outstanding, so no continuous tracking occurs.
- App Store submission will need location declared in the App Privacy questionnaire,
  with the purpose and retention reflecting the web app's actual handling.

---

## 11. Verification performed

Tested on the iOS 26.1 Simulator (iPhone 16e) against a controlled test page that
calls the same API the web app uses:

| Scenario | Result |
| --- | --- |
| Shim installed in page context | Confirmed — `navigator.geolocation.getCurrentPosition` resolves to the bridge |
| Permission not yet decided | iOS system dialog presented, showing the configured purpose string |
| Permission granted, simulated location 12.9716, 77.5946 | Page received exactly those coordinates with valid accuracy and timestamp |
| `watchPosition` and `clearWatch` | Update delivered, watcher cleared, native session stopped |
| Permission denied | Page received error code `1`; native "Open Settings" alert presented |
| Unavailable values | `altitude` correctly reported as `null` |

Both the iOS and macOS builds compile without errors or warnings.

The live SSO link was not exercised during testing, since its token appears to be
single-use.

---

## 12. Scope and limitations

- **When In Use only.** Location is unavailable while the app is backgrounded. This is
  sufficient for address selection.
- **`navigator.permissions.query({ name: 'geolocation' })` is not bridged.** If the web
  app uses it to pre-check permission, it will report WebKit's own state, which does not
  reflect the app-level permission. Recommendation: rely on the `getCurrentPosition`
  error callback instead.
- **Reverse geocoding is not performed natively.** The bridge returns raw coordinates;
  converting them to a street address remains the web app's responsibility.
- **Camera and microphone are not yet bridged.** If any web flow (for example, a
  teleconsultation or document upload) needs them, they require the same treatment plus
  their own purpose strings. This can be added on request.
