/** What a conversation is about. Set by the start button the user picked. */
export type DevReplyCategory = 'bug' | 'billing' | 'idea' | 'question' | 'other'

/** Custom attribute values: text, number or true/false. `null` removes one. */
export type DevReplyAttribute = string | number | boolean | null

/** The app's public keys from the DevReply dashboard (Settings → Platforms). Safe to ship. */
export type DevReplyKeys = { ios?: string; android?: string }


/** Extra context for `present`: a prefilled first message, and values the team sees on that conversation. */
export type DevReplyPresentOptions = {
  /** Prefills the composer of the new conversation (the user sees it and sends it). */
  message?: string
  /** Shown to the team with that conversation only (e.g. `{ source: 'paywall', rc_error_code: '…' }`). */
  attributes?: Record<string, string | number | boolean>
  /** `false` skips "Before we start" (the name form) while this chat is open, e.g. from a failed purchase. */
  askName?: boolean
}

/**
 * The chat's colours as hex strings (`#F6EB37`); any left out keep DevReply's own. DevReply works out
 * the rest (cards, secondary text, outlines, text on colour) from these, and keeps its own line widths.
 */
export type DevReplyThemeColors = {
  /** The header and the brand highlight. */
  primary?: string
  /** Buttons that act: send, start, save. */
  accent?: string
  /** The user's own message bubbles, and their text. */
  userBubble?: string
  userBubbleText?: string
  /** The page, and the text on it. */
  background?: string
  ink?: string
}

/** What happened in the chat, for analytics. */
export type DevReplyEvent =
  | { type: 'messengerOpened' }
  | { type: 'messengerClosed' }
  | { type: 'conversationStarted'; conversationId: string; category: DevReplyCategory | null }
  | { type: 'messageSent'; conversationId: string }
