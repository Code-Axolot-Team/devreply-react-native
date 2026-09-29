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

**Languages:** the chat follows the device's language (15 languages); `DevReply.setLocale('es')` if your app has its
own language setting (`null` follows the device).

**Who replied:** each reply shows the teammate's name, title and photo (their persona in the dashboard), and the
chat's header shows your app icon. Nothing to set up in the app.

**Replies from email:** DevReply emails users replies they haven't read, with a "Reply in the app" button that opens
`yourapp://devreply?devreply=<conversation>`. Give the app a URL scheme (Expo: `"scheme": "yourapp"` in `app.json`)
and set `yourapp://devreply` as the deep link in the dashboard (the app → Settings). The package listens for these
links itself after `configure`; with expo-router add `app/+native-intent.tsx`:
`export function redirectSystemPath({ path }) { return path.includes('devreply=') ? '/' : path }`. If your router
swallows links first, pass them on with `DevReply.handle(url)`.

**Push notifications**, like Intercom: your app keeps its own push setup and passes DevReply the token and, on
Android, DevReply's messages. With @react-native-firebase/messaging:

```ts
import messaging from '@react-native-firebase/messaging'

// iOS: the APNs token; Android: the FCM token.
const token = Platform.OS === 'ios' ? await messaging().getAPNSToken() : await messaging().getToken()
if (token) DevReply.registerPushToken(token)
messaging().onTokenRefresh((t) => Platform.OS === 'android' && DevReply.registerPushToken(t))

// Android: DevReply shows its own notification; a tap opens the conversation.
messaging().onMessage(async (m) => { if (DevReply.handlePush(m.data)) return /* your pushes */ })
messaging().setBackgroundMessageHandler(async (m) => { if (DevReply.handlePush(m.data)) return }) // index.js
```

On iOS, expo-notifications works too: `DevReply.registerPushToken((await Notifications.getDevicePushTokenAsync()).data)`.
Upload your push keys in the dashboard (the APNs key; the Firebase service account for Android). The chat asks
for the notification permission only after the user's first message.

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
```

## License

MIT, see [LICENSE](LICENSE). Issues and ideas welcome: see [CONTRIBUTING](CONTRIBUTING.md).
