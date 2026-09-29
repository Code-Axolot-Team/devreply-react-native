// DevReply for React Native: passes calls through to the native iOS (SwiftUI) and Android (Jetpack
// Compose) SDKs and opens their chat screen. No UI in JavaScript.
//
//   DevReply.configure({ ios: 'pk_…', android: 'pk_…' })   // once, at startup
//   DevReply.present()                                     // from any button
import { Linking, Platform } from 'react-native'

import type { DevReplyAttribute, DevReplyCategory, DevReplyKeys } from './DevReply.types'
import Native from './NativeDevReply'

export * from './DevReply.types'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** The conversation a DevReply link points to (`yourapp://devreply?devreply=<id>`), if it is one. */
function conversationIn(url: string): string | null {
  const m = /[?&]devreply=([^&#]+)/.exec(url)
  const id = m ? decodeURIComponent(m[1]) : null
  return id && UUID.test(id) ? id : null
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

  /** Opens the chat over the current screen. With a category, straight into a new conversation. */
  present(category?: DevReplyCategory): void {
    Native.present(category ?? null)
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

  /** Whether this push (`RemoteMessage.data`) is one of DevReply's. */
  isDevReplyPush(data: Record<string, unknown> | undefined): boolean {
    return typeof data?.devreply_conversation_id === 'string'
  },

  /**
   * Android: shows DevReply's push (a reply from the team) as a notification; a tap opens that
   * conversation. Call it from `messaging().onMessage` and `messaging().setBackgroundMessageHandler`.
   * Returns false for any other message (handle those yourself), and on iOS, where DevReply shows
   * its pushes itself.
   */
  handlePush(data: Record<string, unknown> | undefined): boolean {
    if (Platform.OS !== 'android' || !data || !DevReply.isDevReplyPush(data)) return false
    const strings: Record<string, string> = {}
    for (const [k, v] of Object.entries(data)) strings[k] = String(v ?? '')
    return Native.handlePush(strings)
  },
}

export default DevReply
