# Changelog

Released versions stay supported: the API only grows, and every released version's requests are replayed
against the server on every change.

## 0.4.4

* `DevReply.present(category, { message, attributes })`: prefills the new conversation's message (the user
  sends it) and attaches context the team sees on that conversation (where the chat was opened, an error
  code). Returns false when the chat is switched off.
* `DevReply.isAvailable`: false when the team switched the chat off in the dashboard (no app release needed).
* `DevReply.addEventListener(e => …)`: messengerOpened, messengerClosed, conversationStarted, messageSent.
* `DevReply.setTheme({ light, dark })`: the chat's six colours (primary, accent, userBubble, userBubbleText,
  background, ink) as hex strings. Dark mode is off by default; `dark: 'default'` is DevReply's deep-blue
  theme, `dark: null` turns it off. DevReply derives the rest and keeps its own line widths and icons.
* `deleteUser()` never gives up: if DevReply can't be reached, the device forgets the user now and the
  deletion is retried at the next launches (false = queued).

## 0.4.3

* Signed-in users: `DevReply.login(userId)` after sign-in (your own id for the user; the team sees it, your
  backend can delete the user by it), `DevReply.logout()` on every sign-out (the device forgets the chat;
  the next person starts empty), `await DevReply.deleteUser()` in your delete-account flow (deletes the
  user's data, then logs out; `false` if DevReply couldn't be reached).
* Notification taps from your push library: `DevReply.handleNotificationOpened(…)` opens the conversation
  (`false` for your own). Pass `RemoteMessage.data` from @react-native-firebase/messaging
  (`onNotificationOpenedApp`, `getInitialNotification`) or the whole response from expo-notifications. DevReply
  never takes over your notification handling.
* iOS: a reinstall starts clean (the Keychain outlives the app).

## 0.4.2

* Push notifications on Android, like Intercom: pass the FCM token (`DevReply.registerPushToken(token)`) and
  DevReply's messages (`DevReply.handlePush(message.data)` from `onMessage` and
  `setBackgroundMessageHandler`); the SDK shows the notification and a tap opens the conversation.

## 0.4.1

* A plain React Native module (TurboModule, New Architecture, React Native 0.80+) instead of an Expo module:
  bare React Native apps need no Expo; Expo apps work as before (autolinking and the config plugin).

## 0.4.0

* Replies show who wrote them: the teammate's name, title and photo, once per group of replies.
* The app's icon in the chat's header; the team's faces on the chat's home screen.
* Links from DevReply's emails ("Reply in the app") open the right conversation: caught by the package;
  `DevReply.handle(url)` for routers that swallow them.
* The chat speaks the user's language (15 languages, the device's by default); `DevReply.setLocale('es')`.

## 0.3.2

* First release: opens the native DevReply chat (SwiftUI on iOS, Jetpack Compose on Android) from JavaScript.
