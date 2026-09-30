# DevReply for React Native

The in-app chat between your app's users and you, answered from the [DevReply dashboard](https://app.devreply.com).
This package opens the **native** DevReply chat (SwiftUI on iOS, Jetpack Compose on Android) from JavaScript.
No UI in JavaScript, no web view.

- Home with start buttons (bug, billing, idea, question), the user's conversations, and the chat.
- Photos and files, name first, optional email, "we got it" with your reply time.
- An unread bubble over your app, and the unread count in JavaScript.

Requires iOS 17, Android 8 (API 26) and React Native 0.80+ with the New Architecture (the default since 0.76).
One package for both kinds of app: **bare React Native** (no Expo needed) and **Expo** (prebuild / development
builds). Not in Expo Go (it has native code).

## Install: bare React Native

```sh
npm install @devreply/react-native
```

- **iOS:** in `ios/Podfile` set `platform :ios, '17.0'`, and set the app target's Minimum Deployments to 17.0 in
  Xcode (target → General). Then `cd ios && pod install`.
- **Android:** in `android/build.gradle` set `minSdkVersion = 26`. That's all: the package adds the JitPack
  repository the Android SDK comes from. (If your `settings.gradle` forbids project repositories, add
  `maven { url 'https://jitpack.io' }` to its `dependencyResolutionManagement.repositories`.)
- Rebuild the app (`npx react-native run-ios` / `run-android`).

## Install: Expo

```sh
npx expo install @devreply/react-native
```

Add the config plugin to `app.json` (it sets iOS 17 and Android API 26, and adds JitPack), then rebuild:

```json
{ "expo": { "plugins": ["@devreply/react-native"] } }
```

```sh
npx expo prebuild && npx expo run:ios   # or run:android, or a development build with EAS
```

Using a coding agent? Give it your app's setup guide from the dashboard (Settings → Add DevReply to your app):
it has your keys and does these steps for you.

## Use

```ts
import DevReply from '@devreply/react-native'

// Once, at startup: your public keys from the dashboard (safe to ship). Never a secret key (sk_…).
DevReply.configure({ ios: 'pk_…', android: 'pk_…' })

// From any button
DevReply.present()          // or present('bug')

// Optional
DevReply.setUser({ name: 'Ana', email: 'ana@example.com' })
DevReply.setAttributes({ plan: 'pro', trial: false })
const sub = DevReply.addUnreadListener((count) => setBadge(count))   // sub.remove() to stop
DevReply.showsUnreadBubble = false   // if you show the count yourself
```

**A draft and context:** open a new conversation with text already in the composer (the user sees it and sends
it; nothing is sent on its own) and context for your team, shown with that conversation only as "Opened with"
(text, number or true/false, up to 20):

```ts
DevReply.present('billing', { message: "My purchase didn't go through", attributes: { source: 'paywall', rc_error_code: e.code } })
```

**Switched off in the dashboard:** `present` returns `false` and shows nothing, and the unread bubble hides.
`DevReply.isAvailable` tells you up front, to hide your own "Message us" button.

**Events** for your analytics:

```ts
const events = DevReply.addEventListener((e) => {
  // e.type: 'messengerOpened' | 'messengerClosed' | 'conversationStarted' (conversationId, category) | 'messageSent' (conversationId)
  if (e.type === 'conversationStarted') analytics.track('support_started', { category: e.category })
})
events.remove()   // when you no longer need them
```

**Colours and dark mode:** six colours as hex strings, for light and dark: `primary` (header and highlights),
`accent` (buttons that act), `userBubble`, `userBubbleText`, `background` and `ink` (text). DevReply derives the
rest and keeps its own line widths, shadows, fonts and icons. Dark mode is off by default (the chat stays light);
when on, the chat follows the device's appearance. A side you leave out stays as it is.

```ts
DevReply.setTheme({ light: { primary: '#0A84FF', accent: '#FF9F0A' }, dark: 'default' })   // 'default' = DevReply's "Deep blue"
DevReply.setTheme({ dark: { primary: '#7A3CFF', background: '#101018', ink: '#F2F2F7' } })  // your own dark colours
DevReply.setTheme({ dark: null })                                                          // dark off again
```

**Languages:** the chat follows the device's language (34 languages, Hebrew and Arabic right to left); `DevReply.setLocale('es')` if your app has its
own language setting (`null` follows the device).

**Who replied:** each reply shows the teammate's name, title and photo (their persona in the dashboard), and the
chat's header shows your app icon. Nothing to set up in the app.

**Replies from email:** DevReply emails users replies they haven't read, with a "Reply in the app" button that opens
`yourapp://devreply?devreply=<conversation>`. Give the app a URL scheme (Expo: `"scheme": "yourapp"` in `app.json`)
and set `yourapp://devreply` as the deep link in the dashboard (the app → Settings). The package listens for these
links itself after `configure`; with expo-router add `app/+native-intent.tsx`:
`export function redirectSystemPath({ path }) { return path.includes('devreply=') ? '/' : path }`. If your router
swallows links first, pass them on with `DevReply.handle(url)`. Bare React Native, two checks, or links that arrive
while the app is running are lost:

- **iOS:** if your AppDelegate handles URLs itself (Google Sign-In, Facebook…), end with React Native's handler:

  ```swift
  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if GIDSignIn.sharedInstance.handle(url) { return true } // your own handlers first
    return RCTLinkingManager.application(app, open: url, options: options)
  }
  ```
- **Android:** keep `android:launchMode="singleTask"` on `MainActivity` in `AndroidManifest.xml` (the React Native
  default); with `standard`, the link starts a second copy of the app.

**Push notifications**, like Intercom: your app keeps its own push setup and passes DevReply the token, taps and,
on Android, DevReply's messages. DevReply never takes over your notification handling. With
@react-native-firebase/messaging (its modular API; the old `messaging()` calls crash on v26):

```ts
import {
  getMessaging, getAPNSToken, getToken, onTokenRefresh, onMessage, setBackgroundMessageHandler,
  getInitialNotification, onNotificationOpenedApp,
} from '@react-native-firebase/messaging'

const m = getMessaging()
// iOS: the APNs token; Android: the FCM token.
const token = Platform.OS === 'ios' ? await getAPNSToken(m) : await getToken(m)
if (token) DevReply.registerPushToken(token)
onTokenRefresh(m, (t) => { if (Platform.OS === 'android') DevReply.registerPushToken(t) })

// Android: DevReply shows its own notification; a tap opens the conversation.
onMessage(m, async (msg) => { if (DevReply.handlePush(msg.data)) return /* your pushes */ })
setBackgroundMessageHandler(m, async (msg) => { if (DevReply.handlePush(msg.data)) return }) // index.js

// Taps (iOS, and Android notifications your library shows), including the one that launched the app.
getInitialNotification(m).then((n) => n && DevReply.handleNotificationOpened(n.data))
onNotificationOpenedApp(m, (n) => { if (DevReply.handleNotificationOpened(n.data)) return /* yours */ })
```

With expo-notifications: `DevReply.registerPushToken((await Notifications.getDevicePushTokenAsync()).data)` on iOS,
and pass the whole tap response (Expo puts the push's custom keys inside it; DevReply finds them):

```ts
Notifications.getLastNotificationResponseAsync().then((r) => r && DevReply.handleNotificationOpened(r))
Notifications.addNotificationResponseReceivedListener((r) => { if (DevReply.handleNotificationOpened(r)) return /* yours */ })
```

`handleNotificationOpened` returns false for your own notifications. The dashboard's push card shows
"✓ Taps open the chat" once a tap opened a conversation.
Upload your push keys in the dashboard (the APNs key; the Firebase service account for Android), or let your
coding agent do it with DevReply's MCP tools `set_ios_push_key` and `set_android_push_key`. The chat asks
for the notification permission only after the user's first message.

## Sign-in, sign-out and account deletion

If your app has accounts:

```ts
DevReply.login(user.id)                // after sign-in: your own id for the user, never an email or a secret
DevReply.logout()                      // on every sign-out and account switch
const ok = await DevReply.deleteUser() // in your delete-account flow; false = queued, retried until done
```

- `login` labels the user for your team (the dashboard shows it as "User ID (your app)") and lets your backend
  delete them by it. It doesn't merge chats across devices: the id isn't verified, so it never gives one device
  another's conversations. If another id was signed in on this device, DevReply logs out first.
- `logout` revokes this install and its push token; the device forgets the chat and the next person starts empty.
  The conversations stay with your team.
- `deleteUser` deletes the user's name, email, attributes, conversations, messages and files, then logs out.
  Apple requires account deletion in the app. It never gives up: if DevReply can't be reached, the device forgets
  the user at once and returns `false`, and the deletion is retried at the next launches until the server
  confirms. `true` = deleted now.

Your backend can delete a user too, with a read-and-write secret key (never in an app):

```sh
curl -X DELETE "https://api.devreply.com/v1/project/users?user_id=<your id>" \
  -H "Authorization: Bearer $DEVREPLY_SECRET_KEY"
# {"deleted": 1}: every DevReply user with that id, on every device. ?id=<DevReply's user id> for one user.
```

Your team can also delete a user in the dashboard (the inbox's user panel → Delete user).

## How it's built

`ios/` compiles the DevReply iOS SDK sources (`ios/DevReplySDK`, the same code as
[devreply-ios](https://github.com/Code-Axolot-Team/devreply-ios)) with a TurboModule (`src/NativeDevReply.ts` is the spec; `ios/DevReplyRN.mm` and `ios/DevReplyBridge.swift`
implement it). `android/` implements it in Kotlin over
[devreply-android](https://github.com/Code-Axolot-Team/devreply-android) from JitPack. A plain React Native
module, autolinked by React Native and by Expo alike; `app.plugin.js` is only for Expo. The JavaScript only
passes calls through.

## Example and tests

```sh
npm install
cd example && npm install && echo "EXPO_PUBLIC_DEVREPLY_IOS_KEY=pk_…
EXPO_PUBLIC_DEVREPLY_ANDROID_KEY=pk_…" > .env.local
npx expo prebuild && npx expo run:ios --configuration Release
maestro test -e NONCE=123 maestro/chat.yaml   # with a script replying "Founder reply 123" once the chat is closed
```

The example is an Expo app. For bare React Native, test the packed package (`npm pack`) in a fresh
`npx @react-native-community/cli init` app with the same `App.tsx` and flow.

## License

MIT, see [LICENSE](LICENSE). Issues and ideas welcome: see [CONTRIBUTING](CONTRIBUTING.md).
