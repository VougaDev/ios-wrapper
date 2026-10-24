# VougaDev Native for iOS

The native shell every VougaDev web app ships as its own App Store app: the product's
site in a `WKWebView`, the sign-in in the system's sign-in sheet, a native offline screen, and the native features the
site turns on. It is the Swift package `VougaDevShell` (iOS 17+). Its Android twin is
[VougaDev/android-wrapper](https://github.com/VougaDev/android-wrapper); both expose the same `window.VougaDevNative`.

The shell alone is never submitted: each app adds its own name, icon, site, account-service client and native features
([App Review 4.2](#app-review-checks)).

## The contract: `window.VougaDevNative`

The same on Android and iOS; a page branches on the platform only through `platform()`. Each app's
`docs/integration/native-bridge.md` is the full contract (Ship's is the reference).

| Member | Result | Feature |
|---|---|---|
| `platform()` | `"ios"`, synchronous | always |
| `version()` | the app's `CFBundleShortVersionString`, synchronous | always |
| `startTracking({missionId, url?, intervalSeconds?, target?, title?, text?})` | `Promise<{ok: true} \| {ok: false, error}>` | `.tracking` |
| `stopTracking()` | `Promise<{ok: true}>` | `.tracking` |
| `trackingState()` | `Promise<{active, missionId, lastSentAt, lastError}>` | `.tracking` |
| `openMissions({url?})` | `Promise<{ok: true} \| {ok: false, error: "route_refused"}>` | `.missions` |

- A `WKUserScript` at document start, main frames only, that returns at once unless `location.origin` is the app's;
  and a `WKScriptMessageHandlerWithReply` (`vougadevNative`) that answers `origin_refused` to any frame that is not the
  main frame of the app's origin. Members are fixed in the binary (App Review 2.5.2).
- Every Promise resolves, never rejects; the object is frozen. Calls are `{"method", "args"}` JSON texts, the reply is
  the result's JSON text.
- Error codes: `bridge_unavailable`, `invalid_request`, `origin_refused`, `unknown_method`, `invalid_json`,
  `invalid_mission_id`, `invalid_url`, `tracking_declined`, `location_permission_denied`, `location_disabled`,
  `no_recent_fix`, `network_error`, `http_<status>`, `mission_ended`, `session_lost`, `time_limit`, `route_refused`.
  `foreground_start_refused` never occurs on iOS.
- The user agent is WebKit's own plus `Mobile/15E148 <Token>App/<version> (iOS)`: the site reads it to hide, inside the
  app, everything that names the other platform or its download (App Review 2.3.10).

## What the shell does

| | |
|---|---|
| Sign-in | `ASWebAuthenticationSession` over the app ("<App> wants to use the account service's site to sign in"), PKCE S256, the app's own public client at the account service, never inside the web view. The access token is traded at `POST /auth/app-session/` for the site's session cookie; the refresh token stays in the Keychain (`AfterFirstUnlockThisDeviceOnly`) and renews a lost session silently, one renewal at a time. |
| Sign-out | The web's `POST /auth/logout/` is taken over: the site's session ended, the refresh token revoked, cookies and web data cleared, tracking stopped. The VougaDev session in Safari stays (no `end_session`). |
| Links | The app's pages inside; its sign-in pages run the native sign-in; the account service's own pages, other sites, `tel:`, `mailto:`, maps open outside; `file:`, `javascript:`, `data:`, `blob:`, `about:` are blocked. A same-origin path may open a native screen instead ([`nativeScreen(path:)`](Sources/VougaDevShell/Shell/ShellViewController.swift)). |
| Offline | A native screen (title, sentence, Try again) instead of a browser error, at launch too. |
| Before sign-in | The sign-in screen links the site's privacy page (`privacyPath`, `/privacy/` by default; App Review 5.1.1). From there a visitor reads the site's public pages; their sign-in links come back to the native sign-in. |
| Tracking (`.tracking`) | The disclosure first ([`TrackingDisclosure`](Sources/VougaDevShell/Tracking/TrackingStore.swift)), then Location Services, then While-Using permission (precise asked once more when only approximate is given). Positions are posted every `intervalSeconds` (15…300) to `/api/v1/courier/missions/<id>/position` with `{lat, lon, accuracy_m, fix_at_ms, distance_m}` as the web view's session, in the background too with the location indicator shown; never "Always". Stops on 404 or `not_on_the_road` / `not_started` / `not_your_mission` (after asking `/api/v1/courier/tracking` once for the next mission), on sign-out, on `stopTracking()` and after six hours. Resumed when the app comes back with a mission kept. |
| Missions (`.missions`) | `openMissions` opens `/courier/missions/…` on the app's native screen when it has one, else in the web view. |
| Pages | JavaScript `alert`/`confirm` as native alerts; camera and microphone streams refused; a crashed page process reloaded; swipe back; pull to refresh. |
| Texts | English, French and Spanish ([Resources](Sources/VougaDevShell/Resources)); an app rewords any text in its own `Shell.strings` table (above all `shell_signin_text`, its sign-in sentence). |

Differences from Android, each forced by the platform: Location Services are checked before the permission (iOS shows
no permission dialog while they are off); no notification permission is asked for tracking (the location indicator
shows it); the sign-in sheet takes no toolbar colour; no pull guard over an open modal yet.

## An app on the shell

The app's own repository holds an `ios/` folder: copy [Example](Example) and change what its files mark `APP`.

1. **`project.yml`** (XcodeGen; no `.xcodeproj` is committed): the package (`url: https://github.com/VougaDev/ios-wrapper`
   with an exact `revision`, so every release builds one known commit), the bundle id (the same id as the app on the
   other store keeps one redirect at the account service), the display name, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, and only the
   permissions its features use:
   - `.tracking`: `UIBackgroundModes: [location]`, `NSLocationWhenInUseUsageDescription`,
     `NSLocationTemporaryUsageDescriptionDictionary.Tracking`; never `NSLocationAlwaysAndWhenInUseUsageDescription`;
   - a form with a photo input: `NSCameraUsageDescription`.
2. **Purpose strings and the name in en, fr and es**: `App/<lang>.lproj/InfoPlist.strings`, and
   `CFBundleLocalizations: [en, fr, es]` so the shell's own texts follow the phone's language.
3. **Icon**: `App/Assets.xcassets/AppIcon.appiconset`, one 1024×1024 PNG without transparency.
4. **Configuration** in Swift, once ([Example/App/App.swift](Example/App/App.swift)):

   ```swift
   extension ShellConfig {
       static let app = ShellConfig(
           baseURL: "https://app.example.org",          // the only origin loaded or granted anything
           authBaseURL: "https://auth.example.org",
           authClientID: "<the app's public client id>", // PKCE, no secret; redirect <bundle id>:/oauth2redirect
           userAgentToken: "Ship",                         // " ShipApp/<version> (iOS)"
           authSignInPaths: ["/authorize", "/login"],      // the account service's sign-in pages: native sign-in instead
           features: [.tracking, .missions],
           colors: ShellColors(background: …, text: …, muted: …, accent: …, onAccent: …)
       )
   }
   ```

   `storeName` defaults to the bundle id and must never change once shipped (people would be signed out).
5. **Native screens and members**: subclass `ShellViewController` to return a native screen for a path
   (`nativeScreen(path:)`), append members to `super.bridgeMethods()` (each one in every platform's contract in the
   same release), and use the hooks `onSignedInPage`, `afterNewSignIn`, `beforeSignOut`, `forgetLocalData`. A subclass
   of `AppSession` clears what the app keeps (`beforeSessionEnds`, `afterSignOut`).
6. **The account service**: register `<bundle id>:/oauth2redirect` on the app's client.
7. **The site**: honour the user agent (no other platform, no download offer, no digital sale outside in-app purchase
   inside the iOS app), keep the privacy page and the account service's `/account/delete/` in the account menu.

## Build and test

macOS with Xcode 16 or later, or the CI below; no iPhone is needed (the Simulator runs everything).

```bash
xcodebuild test -scheme VougaDevShell -destination 'platform=iOS Simulator,name=iPhone 16'
```

```bash
brew install xcodegen && cd Example && xcodegen && open VougaDevExample.xcodeproj
```

[`.github/workflows/ios.yml`](.github/workflows/ios.yml) runs the unit tests on a `macos-15` runner, then the example
app's UI tests ([Example/UITests](Example/UITests): the sign-in screen in en, fr and es, the system sign-in sheet, the
offline screen) with their screenshots as an artifact, and checks the texts for other platforms' names, on every push.
It needs no secret. UI tests find the shell's screen by its accessibility identifiers: `shell.panel.title`,
`shell.panel.text`, `shell.panel.button`, `shell.panel.link`.

## TestFlight, once VougaDev is enrolled

Disabled until the Apple Developer Program enrolment (organization VougaDev, D-U-N-S number, 99 USD a year) is
accepted. Then, in each app's repository (never in this public one):

1. **App Store Connect**: create the app with its bundle id; create an API key (Users and Access → Integrations → App
   Store Connect API, role App Manager): a `.p8` file, its key id and the issuer id.
2. **Secrets**: the `.p8` (base64), key id, issuer id and team id as encrypted CI secrets, and locally in a git-ignored
   `secrets/` folder. Nothing of it is committed: `*.p8`, `*.p12`, `*.mobileprovision`, `*.cer` and `secrets/` are in
   `.gitignore`.
3. **Signing**: `DEVELOPMENT_TEAM` set to the team id in `project.yml`, `CODE_SIGN_STYLE: Automatic`; Xcode creates the
   certificate and profile through the API key (`-allowProvisioningUpdates`).
4. **`ExportOptions.plist`** in the app's `ios/`:

   ```xml
   <dict>
     <key>method</key><string>app-store-connect</string>
     <key>destination</key><string>upload</string>
     <key>signingStyle</key><string>automatic</string>
     <key>teamID</key><string>TEAMID</string>
   </dict>
   ```

5. **The job** on `macos-15` (no fastlane), with the key written from the secret to a temporary file:

   ```bash
   xcodegen --spec ios/project.yml
   xcodebuild archive -project ios/App.xcodeproj -scheme App -destination 'generic/platform=iOS' \
     -archivePath build/App.xcarchive -allowProvisioningUpdates \
     -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
     MARKETING_VERSION=<version name> CURRENT_PROJECT_VERSION=<commit count>
   xcodebuild -exportArchive -archivePath build/App.xcarchive -exportOptionsPlist ios/ExportOptions.plist \
     -exportPath build/export -allowProvisioningUpdates \
     -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
   ```

   The export uploads to App Store Connect; the build appears in TestFlight once processed. Delete the key file at the
   end of the job.
6. **Screenshots**: the same runner boots the 6.9" and 6.5" Simulators, signs in the demo account and saves
   `xcrun simctl io booted screenshot` per screen: the app's screens, never a browser's.

## App Review checks

Run the `store-rules` check before every submission. Where this shell stands:

- **4.2 minimum functionality**: the shell gives the native sign-in, the offline screen and background location for
  missions; each app must still name at least two native features its users need (Ship: native missions with offline
  handovers, tracking with its disclosure, scanner, offline map) with review-note steps and a demo account with content.
  An app that cannot is a website and is not submitted.
- **2.3.10**: the shell's texts name no other platform (a unit test and the CI check it); the site hides the rest from
  the iOS user agent.
- **2.5.2**: no code downloaded; the bridge's members and native screens are in the binary.
- **2.5.4 / 5.1.5**: `UIBackgroundModes` is `location` only, used only during a started mission, with the location
  indicator; While-Using only; specific purpose strings in three languages.
- **5.1.1 / 5.1.2**: the disclosure before the first tracking, declining blocks nothing else; privacy page and account
  deletion are the site's, in its account menu.
- **4.8 login services**: the account service offers Google and Telegram. Before the first submission the account service must add Sign in with Apple
  or hide those buttons for iOS clients. That is the account service's work, not the shell's.
- **3.1**: deliveries and goods pay on the site (3.1.3(e)); a digital feature sold inside an app needs in-app purchase.

## Secrets

This repository is public. Firebase files (`GoogleService-Info.plist`), keys (`*.p8`, `*.p12`, `*.pem`), certificates,
provisioning profiles, service-account JSON and `.env` files are git-ignored and never committed; CI uses encrypted
secrets. An account-service client id is public by design (PKCE, no secret).

## License

MIT, see [LICENSE](LICENSE).
