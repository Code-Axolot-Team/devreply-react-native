// DevReply for React Native: passes calls through to the native iOS (SwiftUI) and Android (Jetpack
// Compose) SDKs and opens their chat screen. No UI in JavaScript.
//
//   DevReply.configure({ ios: 'pk_…', android: 'pk_…' })   // once, at startup
//   DevReply.present()                                     // from any button
import { Platform } from 'react-native'

import type { DevReplyAttribute, DevReplyCategory, DevReplyKeys } from './DevReply.types'
import Native from './DevReplyModule'

export * from './DevReply.types'

const DevReply = {
  /** Once, at startup, with the app's public keys (one per platform). Never a secret key (sk_…). */
  configure(keys: DevReplyKeys | string): void {
    const key = typeof keys === 'string' ? keys : Platform.OS === 'ios' ? keys.ios : keys.android
    if (!key?.startsWith('pk_')) {
      console.warn(`DevReply: configure needs this platform's public key (pk_…) for ${Platform.OS}.`)
      return
    }
    Native.configure(key)
  },

  /** Opens the chat over the current screen. With a category, straight into a new conversation. */
  present(category?: DevReplyCategory): void {
    Native.present(category ?? null)
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
    return Native.addListener('onUnreadChange', (e) => listener(e.count))
  },

  /**
   * While a reply is waiting, a small round DevReply button floats over the app and opens it.
   * On by default; turn it off if the app shows `unreadCount` itself.
   */
  set showsUnreadBubble(shows: boolean) {
    Native.setShowsUnreadBubble(shows)
  },

  /**
   * iOS: the APNs device token, as hex (e.g. from expo-notifications `getDevicePushTokenAsync()`).
   * DevReply never asks for permission itself before the user writes; the chat offers it.
   * Android push comes later: this does nothing there.
   */
  registerPushToken(token: string): void {
    if (Platform.OS === 'ios') Native.registerPushToken(token)
  },
}

export default DevReply
