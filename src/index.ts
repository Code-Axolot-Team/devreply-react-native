// DevReply for React Native: passes calls through to the native iOS (SwiftUI) and Android (Jetpack
// Compose) SDKs and opens their chat screen. No UI in JavaScript.
//
//   DevReply.configure({ ios: 'pk_…', android: 'pk_…' })   // once, at startup
//   DevReply.present()                                     // from any button
import { Linking, Platform } from 'react-native'

import type {
  DevReplyAttribute,
  DevReplyCategory,
  DevReplyEvent,
  DevReplyKeys,
  DevReplyPresentOptions,
  DevReplyThemeColors,
} from './DevReply.types'
import Native from './NativeDevReply'

export * from './DevReply.types'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** The conversation a DevReply link points to (`yourapp://devreply?devreply=<id>`), if it is one. */
function conversationIn(url: string): string | null {
  const m = /[?&]devreply=([^&#]+)/.exec(url)
  const id = m ? decodeURIComponent(m[1]) : null
  return id && UUID.test(id) ? id : null
}

/**
 * DevReply's keys from whatever a push library hands over for a tapped notification: the data itself, or
 * an Expo response (a notification straight from APNs has its keys in `request.trigger.payload`, and
 * `content.data` is null).
 */
function devReplyData(notification: unknown): Record<string, string> | null {
  const get = (o: unknown, ...path: string[]): unknown =>
    path.reduce<unknown>((v, k) => (v && typeof v === 'object' ? (v as Record<string, unknown>)[k] : undefined), o)
  const candidates = [
    notification,
    get(notification, 'data'),
    get(notification, 'payload'),
    get(notification, 'notification', 'request', 'trigger', 'payload'),
    get(notification, 'notification', 'request', 'content', 'data'),
    get(notification, 'request', 'trigger', 'payload'),
    get(notification, 'request', 'content', 'data'),
  ]
  for (const c of candidates) {
    const id = get(c, 'devreply_conversation_id')
    if (typeof id === 'string' && UUID.test(id)) return { devreply_conversation_id: id }
  }
  return null
}

let listening = false

const DevReply = {
  /** Once, at startup, with the app's public keys (one per platform). Never a secret key (sk_…). */
  configure(keys: DevReplyKeys | string): void {
    const key = typeof keys === 'string' ? keys : Platform.OS === 'ios' ? keys.ios : keys.android
    if (!key?.startsWith('pk_')) {
      console.warn(`DevReply: configure needs this platform's public key (pk_…) for ${Platform.OS}.`)
      return
    }
    Native.configure(key)
    // The button in DevReply's emails opens the app with a DevReply link: open that conversation.
    if (!listening) {
      listening = true
      void Linking.getInitialURL().then((url) => url && DevReply.handle(url))
      Linking.addEventListener('url', ({ url }) => DevReply.handle(url))
    }
  },

  /**
   * Opens the conversation a DevReply link points to (`yourapp://devreply?devreply=<id>`, from the
   * button in DevReply's emails). `configure` already listens for links; call this only if your router
   * swallows them first. Returns false for any other URL.
   */
  handle(url: string): boolean {
    if (!conversationIn(url)) return false
    Native.handle(url)
    return true
  },

  /**
   * After your user signs in: your own id for them (never an email or a secret). The team sees it next
   * to the user, and your backend can delete the user by it. If someone else was signed in on this
   * device, DevReply logs them out first, so nobody sees someone else's chats.
   */
  login(userId: string): void {
    Native.login(userId)
  },

  /** When your user signs out: DevReply forgets this device's chats; the next person starts empty. */
  logout(): void {
    Native.logout()
  },

  /**
   * When your user deletes their account: deletes their name, email, attributes, conversations,
   * messages and files from DevReply, then logs out. True = deleted now; false = DevReply couldn't reach
   * the server: the device already forgot the user and DevReply keeps retrying at the next launches.
   */
  deleteUser(): Promise<boolean> {
    return Native.deleteUser()
  },

  /**
   * Opens the chat over the current screen. With a category, straight into a new conversation. Options:
   * `message` prefills that conversation's composer (the user sends it), `attributes` go to the team with
   * that conversation only (where it was opened, an error code…). Returns false when the chat is switched
   * off in the dashboard (or DevReply isn't configured): then nothing opens.
   *
   *   DevReply.present('billing', { message: "My purchase didn't go through", attributes: { source: 'paywall' } })
   */
  present(category?: DevReplyCategory | null, options?: DevReplyPresentOptions): boolean {
    return Native.present(category ?? null, options?.message ?? null, options?.attributes ?? {})
  },

  /** False when the team switched the chat off in the dashboard: hide your own "Message us" buttons. */
  get isAvailable(): boolean {
    return Native.isAvailable()
  },

  /**
   * The chat's colours, as hex strings; any left out keep DevReply's own. Dark mode is off by default
   * (the chat stays light); `dark: 'default'` turns on DevReply's dark theme, your own colours turn on
   * yours, `dark: null` turns it off again. A side you leave out stays as it is; `light: null` goes back
   * to DevReply's light colours.
   *
   *   DevReply.setTheme({ light: { primary: '#0A84FF' }, dark: 'default' })
   */
  setTheme(theme: { light?: DevReplyThemeColors | null; dark?: DevReplyThemeColors | 'default' | null }): void {
    const lightMode = theme.light === undefined ? 'keep' : theme.light === null ? 'reset' : 'custom'
    const darkMode = theme.dark === undefined ? 'keep' : theme.dark === null ? 'off' : theme.dark === 'default' ? 'default' : 'custom'
    Native.setTheme(lightMode, lightMode === 'custom' ? (theme.light as object) : null, darkMode, darkMode === 'custom' ? (theme.dark as object) : null)
  },

  /**
   * Called for what happens in the chat (opened, closed, conversation started, message sent), e.g. to
   * measure which button brings conversations. Call `.remove()` on the result to stop.
   */
  addEventListener(listener: (event: DevReplyEvent) => void): { remove(): void } {
    return Native.onEvent((e) => {
      if (e.type === 'conversationStarted') {
        listener({ type: 'conversationStarted', conversationId: e.conversationId ?? '', category: (e.category as DevReplyCategory | null) ?? null })
      } else if (e.type === 'messageSent') {
        listener({ type: 'messageSent', conversationId: e.conversationId ?? '' })
      } else if (e.type === 'messengerOpened' || e.type === 'messengerClosed') {
        listener({ type: e.type })
      }
    })
  },

  /**
   * The chat's language: `es`, `pt-BR`, `ja`… (15 languages; others fall back to English), or null to
   * follow the device. Takes effect at once, even with the chat open.
   */
  setLocale(tag: string | null): void {
    Native.setLocale(tag)
  },

  /** Who the user is, if the app knows. With a name set, the chat doesn't ask for one. */
  setUser(user: { name?: string; email?: string }): void {
    Native.setUser(user.name ?? null, user.email ?? null)
  },

  /** Custom attributes the team sees next to the user (plan, account id…). `null` removes one. */
  setAttributes(attributes: Record<string, DevReplyAttribute>): void {
    Native.setAttributes(attributes)
  },

  /**
   * The user tapped a notification: pass what your push library gives you, and DevReply opens the
   * conversation when it's one of DevReply's (returns false for the app's own). Your push library owns
   * notifications; DevReply only answers "is this mine?". Call it from the tap handlers, including the
   * one for a tap that launched the app:
   * - expo-notifications: `addNotificationResponseReceivedListener(r => DevReply.handleNotificationOpened(r))`
   *   and `getLastNotificationResponseAsync()` (the response itself);
   * - @react-native-firebase/messaging, notifee and others: the notification's data.
   * On Android, DevReply's own notifications (from `handlePush`) open the conversation by themselves.
   */
  handleNotificationOpened(notification: unknown): boolean {
    const data = devReplyData(notification)
    return data ? Native.handleNotificationOpened(data) : false
  },

  /** Unread replies from the team. */
  get unreadCount(): number {
    return Native.getUnreadCount()
  },

  /** Called whenever the unread count changes. Call `.remove()` on the result to stop. */
  addUnreadListener(listener: (count: number) => void): { remove(): void } {
    return Native.onUnreadChange((e) => listener(e.count))
  },

  /**
   * While a reply is waiting, a small round DevReply button floats over the app and opens it.
   * On by default; turn it off if the app shows `unreadCount` itself.
   */
  set showsUnreadBubble(shows: boolean) {
    Native.setShowsUnreadBubble(shows)
  },

  /**
   * The device's push token, so replies arrive as notifications. iOS: the APNs token as hex
   * (@react-native-firebase/messaging `getAPNSToken()`, or expo-notifications `getDevicePushTokenAsync()`).
   * Android: the FCM token (`messaging().getToken()` and `onTokenRefresh`). DevReply never asks for
   * permission itself before the user writes; the chat offers it.
   */
  registerPushToken(token: string): void {
    Native.registerPushToken(token)
  },

  /** Whether this push (its data, or an Expo notification response) is one of DevReply's. */
  isDevReplyPush(notification: unknown): boolean {
    return devReplyData(notification) !== null
  },

  /**
   * Android: shows DevReply's push (a reply from the team) as a notification; a tap opens that
   * conversation. Call it from `messaging().onMessage` and `messaging().setBackgroundMessageHandler`.
   * Returns false for any other message (handle those yourself), and on iOS, where DevReply shows
   * its pushes itself.
   */
  handlePush(data: Record<string, unknown> | undefined): boolean {
    if (Platform.OS !== 'android' || !data || !devReplyData(data)) return false
    const strings: Record<string, string> = {}
    for (const [k, v] of Object.entries(data)) strings[k] = String(v ?? '')
    return Native.handlePush(strings)
  },
}

export default DevReply
