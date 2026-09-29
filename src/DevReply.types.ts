/** What a conversation is about. Set by the start button the user picked. */
export type DevReplyCategory = 'bug' | 'billing' | 'idea' | 'question' | 'other'

/** Custom attribute values: text, number or true/false. `null` removes one. */
export type DevReplyAttribute = string | number | boolean | null

/** The app's public keys from the DevReply dashboard (Settings → Platforms). Safe to ship. */
export type DevReplyKeys = { ios?: string; android?: string }

export type DevReplyModuleEvents = {
  onUnreadChange: (event: { count: number }) => void
}
