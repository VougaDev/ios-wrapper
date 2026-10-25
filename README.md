# VougaDev Native for iOS

The native shell every VougaDev web app ships as its own App Store app: the product's
site in a `WKWebView`, the sign-in in the system's sign-in sheet, a native offline screen, and the native features the
app turns on as extensions. It is the Swift package `VougaDevShell` (iOS 17+): the core, and one library per shared
extension. Its Android twin is
[VougaDev/android-wrapper](https://github.com/VougaDev/android-wrapper); both expose the same `window.VougaDevNative`.

The shell alone is never submitted: each app adds its own name, icon, site, account-service client and native features
([App Review 4.2](#app-review-checks)).

## The contract: `window.VougaDevNative`

The same on Android and iOS; a page branches on the platform only through `platform()`, and on what the app can do
only through `features()`.

| Member | Result | Where |
|---|---|---|
| `platform()` | `"ios"`, synchronous | core |
| `version()` | the app's `CFBundleShortVersionString`, synchronous | core |
| `features()` | the app's extensions, e.g. `["tracking", "offline-map", "missions"]`, synchronous | core |
| `openSettings()` | `Promise<{ok: true}>`: the app's native Settings | core |
| `consent()` | `Promise<{<purpose>: true \| false}>`, all false before the person answered | core |
| `network()` | `Promise<{online, offlinePage, savedAt}>`; the window event `vougadev:network` carries the same | core |
| `openOutside({url, returnUrl})` | `Promise<{ok: true} \| {ok: false, error: "cancelled" \| "failed" \| "invalid_url"}>`: an outside step that refuses web views (a payment provider) in the system sheet, back by itself to `returnUrl` under `outsideReturnPrefix`, loaded in the web view | core, and the payment service's origin (its frames too) |
| `nativeSignIn({provider: "google", nonce})` | `Promise<{ok: true, provider, idToken, …} \| {ok: false, error}>`: Google's sheet, for the account service's Google button; only on its origin and only when the app has a Google client (`googleClientID`) | core |
| `startTracking({missionId, url?, intervalSeconds?, target?, title?, text?})` | `Promise<{ok: true} \| {ok: false, error}>` | `tracking` |
| `stopTracking()` | `Promise<{ok: true}>` | `tracking` |
| `trackingState()` | `Promise<{active, missionId, lastSentAt, lastError}>` | `tracking` |
| (none) | the site's own map tiles work offline | `offline-map` |
| an app's own members | as its contract says (Ship: `openMissions({url?})`) | the app |

- A `WKUserScript` at document start, main frames only, that returns at once unless `location.origin` is the app's;
  and a `WKScriptMessageHandlerWithReply` (`vougadevNative`) that answers `origin_refused` to any frame that is not the
  main frame of the app's origin. Only the members of the extensions the app has exist. Members are fixed in the
  binary (App Review 2.5.2).
- Every Promise resolves, never rejects; the object is frozen. Calls are `{"method", "args"}` JSON texts, the reply is
  the result's JSON text.
- Error codes: `bridge_unavailable`, `invalid_request`, `origin_refused`, `unknown_method`, `invalid_json`; tracking's
  `invalid_mission_id`, `invalid_url`, `tracking_declined`, `location_permission_denied`, `location_disabled`,
  `no_recent_fix`, `network_error`, `http_<status>`, `mission_ended`, `session_lost`, `time_limit`
  (`foreground_start_refused` never occurs on iOS).
- The user agent is WebKit's own plus `Mobile/15E148 <Token>App/<version> (iOS)`. Inside the app the site hides
  everything that names the other platform or its download (App Review 2.3.10), every "install the app" prompt (no PWA
  install, no add-to-home-screen), and its own cookie banner (the app asks natively).

## The core

Every app has it; it is the `VougaDevShell` library.

| | |
|---|---|
| Sign-in | Inside the app (`signInInWebView`): the account service's authorization request (code, PKCE, `ui_locales`) loads in the web view; sign-in, sign-up, passkeys, the account chooser and the first steps all happen there; its final redirect to `<bundle id>:/oauth2redirect` is caught and the code exchanged. A site's `/auth/login/?prompt=create\|login\|select_account` (or `max_age`) starts it with those asks, keeping `next`; a plain one renews silently; the site's own web sign-in never loads. Google through `nativeSignIn`, since it refuses web views. The system sign-in sheet (`ASWebAuthenticationSession`) remains the fallback. PKCE S256, the app's own public client. The access token is traded at `POST /auth/app-session/` for the site's session cookie; the refresh token stays in the Keychain (`AfterFirstUnlockThisDeviceOnly`) and renews a lost session silently, one renewal at a time. |
| Sign-out | The web's `POST /auth/logout/` (or Settings) signs out of this app on this phone: the push token forgotten, each extension's `signOut()`, the site's session ended, the refresh token revoked, cookies and web data cleared. The VougaDev session in Safari stays. |
| Links | One app, one web view: the site, the company's other domains and subdomains (`companyDomains`) and the account service load in the same web view, with one navigation and swipe back. `window.VougaDevNative` exists only on the trusted origins (`trustedOrigins`: the site's, the account service's). An outside company's site opens in an in-app sheet (`SFSafariViewController`); `tel:`, `mailto:`, maps and chat go to the phone's apps; `file:`, `javascript:`, `data:`, `blob:`, `about:` are blocked. An extension may claim a same-origin path for a native screen. |
| Origins | The site's own origin has every member; the account service's `completeSignIn` and `nativeSignIn`; the company's other trusted origins (`trustedOrigins`, the payment service) `openOutside`, in their frames inside the site's pages too. Every origin has `platform`, `version` and `features`. The handler checks the calling frame's origin and member. |
| Errors | Never a raw error page: a 502, 503, 504 or a CDN's 520–530 on a company page, or a page of the site's or the payment service's origin without the company's `<meta name="vougadev-page">` (`requirePageMeta`; an older `siteMarker` text is accepted), is answered as with no network (the saved copy, or what is saved). The site serves its own page for its own errors. |
| Offline | A native screen (title, sentence, Try again) instead of a browser error, at launch too. |
| Before sign-in | The sign-in screen links the site's privacy page (`privacyPath`, `/privacy/` by default). |
| Notifications | Asked once, right after a sign-in, after one native sentence (`shell_push_text`, which the app rewords), never at launch, never a condition. The APNs token goes to the site (`PUT <registerPath>` `{kind: "apns", token, label, platform: "ios", locale, app}`), which hands it to the hub; on sign-out `POST <forgetPath>` `{token}`. A tapped notification `{app, url, screen?, topic, id}`: this app's opens the native screen an extension claims for `screen`, else its page; another app's opens through the system (that app, or Safari); never a blank screen (this app's home). |
| Settings | Native, opened by the page (`openSettings()`, an item of its account menu shown only in the app), never in the site's main menu: version; notifications (system permission, the hub's topics page); "On this phone" (each extension's rows); "Privacy and data" (privacy policy, cookies and data, delete my account at the account service); sign out. |
| Consent | When the app declares purposes: a native dialog, asked once before the first page, each purpose off until turned on; the choice is the first-party cookie `vougadev_consent=<purpose>:1\|<purpose>:0` and `consent()`. Changed in Settings. |
| Pages | JavaScript `alert`/`confirm` as native alerts; camera and microphone streams refused; a crashed page process reloaded; swipe back; pull to refresh. |
| Texts | English, French and Spanish, in an app's words, never a website's: no "page", "site", "web", "link", "browser", "click", "URL", "reload", "tab" (nor their French and Spanish words); `.github/check-words.py` fails the build on one. An app rewords any text in its own `Shell.strings` table. |

## Extensions

An extension is one native feature beyond the core ([`ShellExtension`](Sources/VougaDevShell/Shell/ShellExtension.swift)):
its members of `window.VougaDevNative`, the native screens and notification screens it claims, the Info.plist keys it
needs (checked at launch: a Debug build stops on a missing one), its own disclosure, its rows in Settings, and its
hooks (`attach`, `configure` the web view, `signedInPage`, `becameActive`, `signOut`). **Every app has at least one
real extension**: an app whose `features()` is empty is a web clipping (App Review 4.2.2).

- **`tracking`** ([`VougaDevTracking`](Sources/VougaDevTracking)): a started mission's position shared in the
  background. The disclosure first, then Location Services, then While-Using permission (precise asked once more when
  only approximate is given). Positions are posted every `intervalSeconds` (15…300) to the mission's position address
  with `{lat, lon, accuracy_m, fix_at_ms, distance_m}` as the web view's session, the location indicator shown; never
  "Always". Stops on 404 or `not_on_the_road` / `not_started` / `not_your_mission` (after asking the target address
  once for the next mission), on sign-out, on `stopTracking()` and after six hours. Needs `UIBackgroundModes:
  [location]`, `NSLocationWhenInUseUsageDescription`, `NSLocationTemporaryUsageDescriptionDictionary.Tracking`.
  `TrackingExtension(paths: TrackingPaths(position: "/…/{id}/position", target: "/…"))`.
- **`offline-map`** ([`VougaDevOfflineMap`](Sources/VougaDevOfflineMap)): the regions the site lists
  (`manifestPath`: `{available, tilesets: [{source, name, size, version, url}]}`, `.mbtiles` files) are downloaded on
  Wi-Fi once signed in, and the site's own tile requests (`tilePath`, e.g. `/tiles/{source}/{z}/{x}/{y}`) are answered
  from them, so the site's maps keep working with no network. WebKit answers only an app's own URL schemes, so a
  document-start script sends those requests (from the page and the workers it starts) to `vougadev-tiles:`, answered
  from the file, else from the network with the web view's session. Settings shows the size and deletes them.
- **An app's own** (Ship's `missions`): in the app's repository, the same protocol.

## An app on the shell

The app's own repository holds an `ios/` folder: copy [Example](Example) and change what its files mark `APP`.

1. **`project.yml`** (XcodeGen; no `.xcodeproj` is committed): the package (`url: https://github.com/VougaDev/ios-wrapper`
   with an exact `revision`) and the libraries it uses (`VougaDevShell`, `VougaDevTracking`, `VougaDevOfflineMap`), the
   bundle id (the same as on the other store keeps one redirect at the account service), the display name, versions,
   and only the Info.plist keys its extensions need (plus `NSCameraUsageDescription` for a form's photo input).
2. **Purpose strings and the name in en, fr and es**: `App/<lang>.lproj/InfoPlist.strings`, and
   `CFBundleLocalizations: [en, fr, es]`; the app's own sentences (sign-in, notifications) in `App/<lang>.lproj/Shell.strings`.
3. **Icon**: `App/Assets.xcassets/AppIcon.appiconset`, one 1024×1024 PNG without transparency.
4. **Configuration and extensions** in Swift, once ([Example/App/App.swift](Example/App/App.swift)):

   ```swift
   extension ShellConfig {
       static let app = ShellConfig(
           baseURL: "https://app.example.org",            // the only origin loaded or granted anything
           authBaseURL: "https://auth.example.org",
           authClientID: "<the app's public client id>",   // PKCE, no secret; redirect <bundle id>:/oauth2redirect
           userAgentToken: "Ship",                           // " ShipApp/<version> (iOS)"
           colors: ShellColors(background: …, text: …, muted: …, accent: …, onAccent: …),
           authSignInPaths: ["/authorize", "/login"],        // the account service's sign-in pages: native sign-in instead
           accountDeletionURL: "https://auth.example.org/account/delete/",
           push: ShellPush.Settings(appSlug: "<the hub's name for the app>", preferencesURL: "<the hub's topics page>"),
           consent: nil                                      // or the purposes the site asks consent for
       )
   }

   let session = AppSession(config: .app, extensions: [
       TrackingExtension(paths: TrackingPaths(position: "/api/…/{id}/position", target: "/api/…/tracking")),
       OfflineMapExtension(config: OfflineMapConfig(manifestPath: "/api/…/offline", tilePath: "/tiles/{source}/{z}/{x}/{y}")),
   ])
   ```

   The app delegate makes the session at launch and hands APNs' token to `session.push?.didRegister(deviceToken:)`.
   `storeName` defaults to the bundle id and must never change once shipped (people would be signed out).
5. **The account service**: register `<bundle id>:/oauth2redirect` on the app's client.
6. **The site**: honour the user agent (no other platform, no download or install prompt, no digital sale outside
   in-app purchase, no cookie banner inside the app), and an account-menu item, shown only inside the app, that calls
   `VougaDevNative.openSettings()`.

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
