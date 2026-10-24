# VougaDev Native for iOS

The native shell every VougaDev web app (Ship, PIVO, Jobs, Civis, Care…) ships as its own store app: the product's site
in a WebView, plus native features the site cannot have. Each app configures its origin, name, icon, colours, VougaDev
account (the account service) client and the native features it enables.

## The contract: `window.VougaDevNative`

The same on Android and iOS; a page branches on the platform only through `platform()`.

| Member | Result |
|---|---|
| `platform()` | `"android"` or `"ios"`, synchronous |
| `version()` | the app's version name, synchronous |
| `startTracking({missionId, url?, intervalSeconds?, target?, title?, text?})` | `Promise<{ok: true} \| {ok: false, error}>` |
| `stopTracking()` | `Promise<{ok: true}>` |
| `trackingState()` | `Promise<{active, missionId, lastSentAt, lastError}>` |
| `openMissions({url?})` | `Promise<{ok: true} \| {ok: false, error: "route_refused"}>` |

- Injected only into the app's own origin, never into another origin's frame.
- Every Promise resolves, never rejects. The object is frozen.
- The user agent ends with ` <App>App/<version> (iOS)`.

## Rules every app built on it keeps

- **Sign-in in the system's sign-in surface, never inside the WebView:** AppAuth with a Custom Tab on Android,
  `ASWebAuthenticationSession` on iOS.
- **Real native features**, never a plain website loader (App Store guideline 4.2). Examples: background location for a
  mission, offline data, the camera scanner, push notifications.
- **No other platform named inside the app.** No self-update outside the store. Privacy policy and account deletion
  reachable inside the app. A disclosure before background location.

Work in progress: the code moves here from Ship's app, where it runs in production today.

## License

MIT, see [LICENSE](LICENSE).
