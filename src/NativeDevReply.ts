// The native module's shape. React Native's codegen reads this file and generates the iOS and Android
// interfaces the bridge implements (ios/DevReplyRN.mm, android/.../DevReplyModule.kt).
import { TurboModuleRegistry, type CodegenTypes, type TurboModule } from 'react-native'

export interface Spec extends TurboModule {
  configure(publicKey: string): void
  login(userId: string): void
  logout(): void
  deleteUser(): Promise<boolean>
  present(category: string | null): void
  setUser(name: string | null, email: string | null): void
  setAttributes(attributes: CodegenTypes.UnsafeObject): void
  getUnreadCount(): number
  setShowsUnreadBubble(shows: boolean): void
  registerPushToken(token: string): void
  handlePush(data: CodegenTypes.UnsafeObject): boolean
  handleNotificationOpened(data: CodegenTypes.UnsafeObject): boolean
  handle(url: string): void
  setLocale(tag: string | null): void
  readonly onUnreadChange: CodegenTypes.EventEmitter<{ count: number }>
}

export default TurboModuleRegistry.getEnforcing<Spec>('DevReply')
