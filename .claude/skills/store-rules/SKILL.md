---
name: store-rules
description: Use before building, changing, releasing or submitting ANY VougaDev native app (Android or iOS wrapper around a web app, window.VougaDevNative), and whenever Echo mentions the App Store, Play Store, Apple review, "Article 4.2", a ban, a rejection, store screenshots or listings. Lists the Apple App Review Guidelines and Google Play policies that get web-wrapper apps rejected or banned (4.2 minimum functionality, 2.3.10 other platforms, 3.1 payments, 4.8 login, 5.1.1 privacy and account deletion, 5.1.5 location; Play's self-update ban, prominent disclosure, account deletion, data safety), and runs the check that none of them is visible inside the app on either platform.
---

# Store rules for VougaDev's native apps

Every VougaDev product is a web app. Its phone app is a native shell that loads the site in a WebView, plus native
features the site cannot have. The shell exposes them as `window.VougaDevNative`; its contract is in each project's
`docs/integration/native-bridge.md`, and every platform reproduces it exactly. Both stores reject or remove apps that
break the rules below. The web pages are part of the app: anything a page shows inside the app counts as the app's own
content. Check the app with each platform's user agent, not only the website.

Source documents. Read them again before a first submission: they change.
- Apple: https://developer.apple.com/app-store/review/guidelines/
- Google: https://support.google.com/googleplay/android-developer/answer/9888379 (Device and Network Abuse), the User
  Data policy, Permissions and APIs that Access Sensitive Information, Spam and Minimum Functionality.

## The rules, and how a VougaDev app meets each

### Apple 4.2: Minimum functionality, "more than a repackaged website" (also 4.2.2: no web clippings)

The main reason web wrappers are rejected. The app must do what Safari cannot:
- **Native features that matter to the job.** Background location for a mission, offline data and maps, a camera
  scanner, offline actions queued and sent later, push notifications. Ship's courier app has all of them natively.
- **Native screens for the core flow.** Ship's missions are native, not WebView pages.
- **No browser chrome.** No address bar, and no "open in browser" for the app's own pages. Sign-in in the system browser session (`ASWebAuthenticationSession` on iOS,
  AppAuth on Android) is fine.
- **Offline is the test reviewers run first, and a dead end fails it.** "Page unavailable, check your connection,
  retry" is a website's error, however native its drawing: it is what 4.2 calls a repackaged website. With no network
  the app must stay useful:
  - it opens on what the person had: the pages already visited, served from the phone (an offline cache of the site's
    pages and their assets), with a quiet "Offline: last updated at …" bar;
  - native screens that work offline (Ship: the courier's missions, their map, the handovers recorded and sent when
    the network returns);
  - actions that need the network are queued, or said to be waiting, and are never just refused;
  - only a page never visited says it is not available offline, and it offers what is (the cached pages, the native
    screens), never a lone "retry" button.
  - A first launch with no network shows the app's own welcome, not an error.
- **An app's words, never a website's** (Apple's Human Interface Guidelines; 4.2 "feels like a website"). Every text the
  person sees inside the app, native or a page of the site, avoids web vocabulary:

  | Never | Say instead |
  |---|---|
  | page / page / página ("Page introuvable", "page précédente", "cette page") | what it is: "Introuvable", "Retour", "le suivi de l'envoi", "ce qui suit", or the screen's own name |
  | site, web, browser / navigateur / navegador | the app's name, or nothing |
  | click / cliquer / hacer clic | tap / touchez / toque, or just the action ("Envoyer") |
  | link / lien / enlace, URL, address bar | the thing it opens |
  | reload / recharger / recargar, refresh the page | "Réessayer", or pull to refresh |
  | tab / onglet (a browser's), download the page, bookmark | nothing |
  | "Page unavailable", "This page could not be loaded" | "Hors connexion", "Pas encore enregistré sur ce téléphone" |

  Texts that leave the app (an SMS or e-mail carrying a URL) may say "lien" or "page": they are read in another app.
  Native strings come from the app's catalogue in en, fr and es; check all three.
- **One app, one WebView, every company domain** (Echo, 2026-10-24). A WebView is not limited to one domain: the app's
  site, the company's other domains and subdomains, and the account service's pages all load in the SAME WebView, with
  one navigation and the native back. No "close" button, no seam, never the browser.
  - The bridge (`VougaDevNative`) is injected on a configured list of trusted company origins, never on others.
  - **Sign-in happens inside the app.** The account service's sign-in page loads in the WebView. Once signed in, it
    calls the shell through the bridge with the authorisation code, and the shell trades it for the app's tokens. No
    redirect to a custom scheme, no browser.
  - **Other companies' logins go native**, because they refuse WebViews. The page asks the shell, which uses the
    platform's own sign-in: Google through Android's Credential Manager and Google's iOS sign-in, Apple through the
    native Sign in with Apple sheet. The token goes back to the account service.
  - **Passkeys work in the WebView** once the app is declared for the account domain: Digital Asset Links with
    WebView WebAuthn support on Android, Associated Domains (`webcredentials:`) on iOS.
  - **Payment stays in the WebView too.** The company's checkout (VougaPay, a company domain) is just another page.
    Only a step from an outside company that refuses WebViews (a bank's 3-D Secure page, a mobile-money operator's
    confirmation, Google Pay or Apple Pay) is handed to an in-app sheet (Custom Tab / `SFSafariViewController`, or the
    native Google Pay / Apple Pay sheet through the bridge). It returns to the WebView by itself once done. If such a
    page works in the WebView, it stays there.
  - **Outside sites the person chose to open** (a map, another company's site) open in an in-app sheet. `tel:`,
    `mailto:`, maps and chat links open the phone's own app.
- **Company pages shown inside the apps** (the app's site, the account service, the checkout) follow the platforms'
  own interface rules (Apple's Human Interface Guidelines, Material Design), not a website's:
  - touch targets of at least 44 pt (iOS) / 48 dp (Android); nothing that works only on hover;
  - the safe areas respected (`env(safe-area-inset-*)`, `viewport-fit=cover`): nothing under the notch or the
    home indicator;
  - dialogs on a phone are bottom sheets or full-screen, with the main action at the bottom within thumb reach;
  - no web words (the table above), no "open in a new tab", no browser-only gestures;
  - they read the app's user agent (` <App>App/<version> (Android|iOS)`) to adapt layout and wording, server-side and
    inside iframes alike. They use `VougaDevNative` (where injected) only for actions.
- **An outside step that must leave the WebView** (PayPal, a bank's 3-D Secure, an operator's page that refuses
  WebViews) opens in the system's sheet that can watch for its return. On iOS, `ASWebAuthenticationSession` with an
  https callback; on Android, Chrome's Auth Tab with an https callback (a Custom Tab as fallback). The provider's return
  address is a company-domain https path declared for every app (`assetlinks.json` and `apple-app-site-association`
  on that domain). When the sheet reaches it, the sheet closes by itself and the WebView loads it.
- **Never a raw error page.** A bare "Not Found", "Bad Gateway", a proxy's or CDN's error page, or a framework's
  debug or CSRF page inside the app is a website showing through (4.2, and 2.1 completeness):
  - the site serves its own page for every HTTP error (400, 403, 404, an expired form, 500), in its own layout and
    language, with one sentence saying what happened and a way back (home, previous page). The 500 page needs nothing
    that may have failed (no database, no menu). The API keeps its JSON errors;
  - the shell catches a main-frame error that does not come from the site (502, 503 or 504 from the edge, a CDN's
    error page, a timeout). It treats it as offline: the last cached copy of the page with a native bar, or the
    native "not available" screen, never the raw page.
- **The shell's core alone is never enough.** Core = the WebView, the system sign-in, the link rules, the offline
  screen. Every app enables at least one real native extension that matters to its users: `tracking`, `offline-map`
  (the site's own maps keep working offline), a scanner, push, or its own native screens. An app whose
  `VougaDevNative.features()` is empty is a web clipping (4.2.2) and will be rejected.
- **Review notes** list these features with the steps to see them, and give a **demo account** that has content
  (2.1). Without content, the reviewer sees an empty website and rejects it.
- **4.2.6 / 4.3 (templates and spam).** The shared VougaDev shell is our own code, not a commercial generator, so one
  app per product is fine. Each app must still have its own name, icon, content and native features. Never submit two
  apps that are the same app with different names.

### Apple 2.3.10 and Google metadata: no other platform inside the app

- Inside the iOS app: no "Android", "Google Play", ".apk", Android robot, nor any link to the APK page.
- Inside the Android app: no ".apk" download offer, and no instructions to install from outside Play (see the
  self-update ban below).
- The same applies to screenshots and store texts.
- Pages tell the platform from the user agent: ` <App>App/<version> (Android|iOS)`. Ship hides the download page's link
  and the home's app link inside the app, and offers only the app's own store for updates.

### Apple 2.5.2 and Google Device and Network Abuse: no code downloaded, no self-update

- **iOS:** the app never downloads executable code that changes its features. A website loaded in the WebView is fine;
  a downloaded native plugin or a JavaScript bundle that unlocks native APIs is not. The bridge's methods are fixed in
  the binary.
- **Android:** an app installed from Play never updates itself, and never installs APKs, except through Play. So
  inside the app no page offers an APK, and the app has no `REQUEST_INSTALL_PACKAGES`. The website (in a browser) may
  offer the APK.

### Apple 3.1: payments

- Physical goods and services used outside the app (a delivery, a ride, goods) must NOT use in-app purchase (3.1.3(e)).
  The site's own checkout is fine.
- Digital content or features unlocked inside the app (a subscription, premium features, credits spent in the app)
  MUST use in-app purchase. Inside the iOS app such pages must hide the purchase and every link to buy it on the
  web. This matters for any app that sells subscriptions, premium features or credits.
- Google Play: physical goods and services are exempt from Play Billing; digital goods follow the same logic.

### Sign-in outside the WebView: required, and done the right way

- Superseded for the company's own account service: see "One app, one WebView, every company domain" (sign-in inside
  the WebView, finished through the bridge, with native sheets for Google and Apple). The system sign-in surface below
  remains the fallback for an account service that cannot call the shell yet:
  - Android: AppAuth with a Chrome Custom Tab (a tab on top of the app, with a close button), never the full browser
    app;
  - iOS: `ASWebAuthenticationSession`, the system sheet "<App> wants to use <sign-in domain> to sign in".
- **Apple rejects (4.0 Design) an app that sends people OUT to Safari to log in.** The sheet above is what Apple asks
  for instead, so it does not count against 4.2.
- If a person feels "the app left": the tab or sheet must show the app's colours (toolbar colour), come back to the app
  by itself once signed in, and never leave a blank tab behind.

### Apple 4.8: login services

- If the sign-in offers Google, Telegram or another third-party login, iOS also requires an equivalent
  privacy-preserving login: Sign in with Apple, or one that limits data to name and e-mail, can hide the e-mail, and
  does no ad tracking.
- If the account service offers Google, Telegram or another social login: before the first iOS submission, either it
  adds Sign in with Apple, or it hides the social buttons when the client is an iOS app (then "own account
  system only" applies).
- This is the account service's work, not the app's.

### Apple 5.1.1 and Google User Data: privacy and account deletion

- **Privacy policy:** linked in the store listing AND easy to find inside the app. A "Privacy and data" screen reached
  from the account menu (or the native settings) is right: a few taps away, never in the way of daily use. The policy
  says what is collected, why, who receives it, how long it is kept, and how to ask for deletion.
- **Account deletion inside the app:** required by both stores when accounts can be created. It sits on that "Privacy
  and data" screen, not in the main menu: a direct link to the account service's deletion page is accepted. Google
  also wants that URL in the Data safety form.
- **Data safety (Google) and the privacy "nutrition label" (Apple):** must match what the code sends: location, name,
  e-mail, phone, photos. No tracking, no ads unless declared.

### Apple 5.1.5, Apple 2.5.4, Google location policy: location

- **Purpose strings (iOS)** say exactly why: `NSLocationWhenInUseUsageDescription`, and
  `NSLocationAlwaysAndWhenInUseUsageDescription` only if "Always" is asked. Background mode `location` only for
  missions (2.5.4).
- **Prominent disclosure (Google; good practice on iOS):** a screen of our own, before the system prompt, says the
  position is collected "even when the app is closed or not in use", why, and when it stops. The person agrees or
  declines; nothing is tracked before they agree, and a refusal blocks nothing else (Apple 5.1.2: no function may
  require it). The shells provide it before the first tracking start.
- **Android:** a foreground service of type `location`, started while the app is visible, with its notification
  shown. Never `ACCESS_BACKGROUND_LOCATION` unless truly needed: it brings a separate Play review and video.
- **Play Console:** the foreground-service declaration needs a short video of start, notification and stop.

### Notifications, install prompts, consent

- **Notifications:** ask right after sign-in, with one sentence saying what will be sent and why, then the system
  prompt. Never at first launch with no reason, and never as a condition to use the app (Apple 5.1.2, 4.5.4).
  Managing them (per topic) is part of the core: a native screen, or the account service's page, reachable from
  "Privacy and data". Never send ads by push unless the person opted in.
- **One hub sends every app's notifications.** Each push therefore says which app it belongs to and what it opens: a
  page of that app's site, or a native screen through the app's own extension. Tapped in another app, or with the
  target app missing, it opens the page in the browser. It never opens a blank screen.
- **No "install the app" prompt, button or banner inside the app** (no PWA install, no add-to-home-screen): the page
  hides them when the app's user agent or `VougaDevNative` is present.
- **Cookie or data consent:** inside the app, a native dialog asked once, never the website's banner over the
  WebView. The choice is passed to the site, and the site hides its own banner in the app.

### Other reasons for rejection

- **Apple 2.1, completeness:** no placeholder pages, no "coming soon", no dead links, and no crash with no network.
  Reviewers sit in the US (Apple) or anywhere (Google): a map that holds only the product's country is blank where
  they are. A world base at low zoom is required under the country's detailed tiles, and the demo account's missions
  must open where the map has detail.
- **Push:** the permission is asked in context, never at first launch with no reason. Notifications never carry ads
  unless the person opted in.
- **Apple 4.0 design, and Echo's rules:** no web-looking hamburger-only app. Native-feeling screens, safe areas,
  Dynamic Type for native screens, dark mode.

## The check (run it before any store build or submission)

Report each line as done, failed and fixed, or skipped (with why). Never say "compliant" after a partial check.

1. **Pages inside the app, both platforms.** Crawl the site with a headless browser, with
   each in-app user agent:
   - Android: `... ShipApp/1.0.0 (Android)`;
   - iOS: `Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 ShipApp/1.0.0 (iOS)`.

   Do it for every role and every page.
   - Fail with the iOS user agent if a page shows `Android`, `Google Play`, `.apk`, `bi-android`, `bi-google-play`,
     or a link to `/app/` or `/static/download/`.
   - Fail with either user agent if a page offers a `.apk` or install instructions.
   - Fail with the iOS user agent if a page sells a digital feature, unless through in-app purchase.
   - Fail with either user agent if "Privacy and data" (policy, account deletion, notification settings) is more than
     about 3 taps away, if a page shows an install prompt, or if the site's cookie banner appears in the app.
2. **Native texts and in-app words.** Grep every catalogue (en, fr, es), native and the site's, for web vocabulary:
   `page|página|site|web|navigateur|navegador|browser|cliqu|click|clic|lien|link|enlace|URL|recharg|reload|recarg|onglet|tab`.
   Every hit shown inside the app is reworded; SMS and e-mail texts with a URL may stay. Grep the native resources for
   `Android|Google Play|apk|Play Store` in the iOS project, and for
   `apk|install` in the Android one. Also grep for placeholder text, "TODO", and other products' names (e.g. "PIVO").
3. **Manifest and plist.**
   - Android: no `REQUEST_INSTALL_PACKAGES`, no `ACCESS_BACKGROUND_LOCATION` unless it is declared and justified, a
     foreground service of type `location` only.
   - iOS: purpose strings present and specific; `UIBackgroundModes` limited to `location` and `remote-notification`.
4. **Disclosure.** On a fresh install, the first tracking start shows the disclosure before any system prompt.
   Declining starts nothing and blocks nothing else.
5. **Offline.** In airplane mode, after a first signed-in visit:
   - relaunch: the app opens on the last pages from the phone, with the native screens;
   - tap through them, and try an action, which must be queued or wait, never fail.
   Any screen that is only "unavailable / retry" fails the check.
6. **Errors.** Open a missing address, a forbidden page, and an expired form (a POST with a wrong CSRF token). Each one
   shows the site's own page with a way back. With the site stopped behind the edge (or its 502 page simulated), the
   app shows its cached page or native screen, never the edge's page.
7. **4.2 evidence.** List the native features with the steps to see each one, for the review notes. Make sure the demo
   account has missions and shipments.
8. **Login (iOS only).** Check whether the sign-in page shows Google or Telegram for this client. If it does, Sign in
   with Apple must be present.
9. **Store listings.** The screenshots come from the app (not a browser) and show no other platform. The texts tell a
   story, as Echo's selling rules ask. The privacy URL, the support URL and the account deletion URL are filled in.

## Building iOS without a Mac

- Xcode runs only on macOS. iOS builds and App Store uploads need macOS: a Mac, or a hosted macOS runner (GitHub
  Actions `macos-15`, Codemagic, Bitrise). `xcodebuild` and the App Store Connect API upload run there.
- An iPhone is not required:
  - the Simulator runs on the macOS runner, and store screenshots come from it (6.9" and 6.5" sizes);
  - TestFlight testers can use any iPhone later.
- An Apple Developer Program membership (99 USD a year) is required to sign and submit, enrolled as an organization
  for VougaDev.
