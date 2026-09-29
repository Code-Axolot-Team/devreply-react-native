# DevReply for React Native

The in-app chat between your app's users and you, answered from the [DevReply dashboard](https://app.devreply.com).
This package opens the **native** DevReply chat (SwiftUI on iOS, Jetpack Compose on Android) from JavaScript.
No UI in JavaScript, no web view.

- Home with start buttons (bug, billing, idea, question), the user's conversations, and the chat.
- Photos and files, name first, optional email, "we got it" with your reply time.
- An unread bubble over your app, and the unread count in JavaScript.

Requires iOS 17 and Android 8 (API 26). Works with Expo (prebuild / development builds) and bare React Native
with Expo modules. Not in Expo Go (it has native code).

## Install

```sh
npx expo install @devreply/react-native
```

Add the config plugin to `app.json` (it sets iOS 17 and Android API 26, and adds JitPack for the Android SDK), then rebuild:

```json
{ "expo": { "plugins": ["@devreply/react-native"] } }
```

```sh
npx expo prebuild && npx expo run:ios   # or run:android
```

Bare React Native: install `expo` modules support (`npx install-expo-modules`), set the iOS deployment target to
17.0, `minSdkVersion` 26, and add `maven { url 'https://jitpack.io' }` to `allprojects.repositories` in
`android/build.gradle`.

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

**Push (iOS):** pass the APNs device token as hex, e.g. from expo-notifications:
`DevReply.registerPushToken((await Notifications.getDevicePushTokenAsync()).data)`, and upload your APNs key in
the dashboard. Android push comes later.

## How it's built

`ios/` compiles the DevReply iOS SDK sources (`ios/DevReplySDK`, the same code as
[devreply-ios](https://github.com/Code-Axolot-Team/devreply-ios)) with a thin Expo module. `android/` depends on
[devreply-android](https://github.com/Code-Axolot-Team/devreply-android) from JitPack. The JavaScript only passes calls through.

## Example and tests

```sh
npm install && npm run build
cd example && echo "EXPO_PUBLIC_DEVREPLY_IOS_KEY=pk_…
EXPO_PUBLIC_DEVREPLY_ANDROID_KEY=pk_…" > .env.local
npx expo prebuild && npx expo run:ios --configuration Release
maestro test -e NONCE=123 maestro/chat.yaml   # with a script replying "Founder reply 123" from the dashboard API
```

## License

MIT, see [LICENSE](LICENSE). Issues and ideas welcome: see [CONTRIBUTING](CONTRIBUTING.md).
