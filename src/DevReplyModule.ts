import { NativeModule, requireNativeModule } from 'expo'

import type { DevReplyModuleEvents } from './DevReply.types'

declare class DevReplyNativeModule extends NativeModule<DevReplyModuleEvents> {
  configure(publicKey: string): void
  present(category: string | null): void
  setUser(name: string | null, email: string | null): void
  setAttributes(attributes: Record<string, string | number | boolean | null>): void
  getUnreadCount(): number
  setShowsUnreadBubble(shows: boolean): void
  registerPushToken(hexToken: string): void
}

export default requireNativeModule<DevReplyNativeModule>('DevReply')
