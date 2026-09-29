package com.devreply.reactnative

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.snapshotFlow
import com.devreply.sdk.DevReply
import com.devreply.sdk.DevReplyCategory
import com.devreply.sdk.DevReplyEvent
import com.devreply.sdk.DevReplySubscription
import com.devreply.sdk.DevReplyTheme
import androidx.compose.ui.graphics.Color
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

// The React Native bridge (the TurboModule "DevReply", src/NativeDevReply.ts): every call goes to the
// native DevReply SDK, on the main thread.
class DevReplyModule(private val context: ReactApplicationContext) : NativeDevReplySpec(context) {
  private val main = Handler(Looper.getMainLooper())
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private var watching: Job? = null
  @Volatile private var unread = 0

  /** The current screen if there is one (the unread bubble then shows on it straight away), else the app. */
  private val screen get() = context.currentActivity ?: context

  override fun configure(publicKey: String) {
    main.post {
      DevReply.configure(screen, publicKey)
      watchUnread()
      forwardEvents()
    }
  }

  private var events: DevReplySubscription? = null

  /** What happens in the chat, for the app's analytics (`addEventListener` in JavaScript). */
  private fun forwardEvents() {
    if (events != null) return
    events = DevReply.addEventListener { event ->
      val map = Arguments.createMap()
      when (event) {
        is DevReplyEvent.MessengerOpened -> map.putString("type", "messengerOpened")
        is DevReplyEvent.MessengerClosed -> map.putString("type", "messengerClosed")
        is DevReplyEvent.ConversationStarted -> {
          map.putString("type", "conversationStarted")
          map.putString("conversationId", event.conversationId)
          map.putString("category", event.category?.name?.lowercase())
        }
        is DevReplyEvent.MessageSent -> {
          map.putString("type", "messageSent")
          map.putString("conversationId", event.conversationId)
        }
      }
      if (!map.hasKey("conversationId")) map.putNull("conversationId")
      if (!map.hasKey("category")) map.putNull("category")
      emitOnEvent(map)
    }
  }

  override fun login(userId: String) {
    main.post { DevReply.login(userId) }
  }

  override fun logout() {
    main.post { DevReply.logout() }
  }

  override fun deleteUser(promise: com.facebook.react.bridge.Promise) {
    main.post { DevReply.deleteUser { ok -> promise.resolve(ok) } }
  }

  override fun present(category: String?, message: String?, attributes: ReadableMap): Boolean {
    if (!DevReply.isAvailable) return false
    val values = attributes.toHashMap().filterValues { it != null }.mapValues { it.value!! }
    main.post {
      DevReply.present(
        screen,
        DevReplyCategory.entries.firstOrNull { it.name.equals(category, ignoreCase = true) },
        message,
        values,
      )
    }
    return true
  }

  override fun isAvailable(): Boolean = DevReply.isAvailable

  /** lightMode: keep | reset | custom; darkMode: keep | off | default | custom. Colours are hex strings. */
  override fun setTheme(lightMode: String, light: ReadableMap?, darkMode: String, dark: ReadableMap?) {
    val lightColors = light?.toHashMap()
    val darkColors = dark?.toHashMap()
    main.post {
      when (lightMode) {
        "reset" -> DevReply.theme = DevReplyTheme()
        "custom" -> DevReply.theme = theme(lightColors, DevReplyTheme())
      }
      when (darkMode) {
        "off" -> DevReply.darkTheme = null
        "default" -> DevReply.darkTheme = DevReplyTheme.Dark
        "custom" -> DevReply.darkTheme = theme(darkColors, DevReplyTheme.Dark)
      }
    }
  }

  private fun theme(colors: Map<String, Any?>?, base: DevReplyTheme): DevReplyTheme {
    fun c(key: String): Color? = (colors?.get(key) as? String)?.let(::parseHex)
    return base.copy(
      primary = c("primary") ?: base.primary,
      accent = c("accent") ?: base.accent,
      userBubble = c("userBubble") ?: base.userBubble,
      userBubbleText = c("userBubbleText") ?: base.userBubbleText,
      background = c("background") ?: base.background,
      ink = c("ink") ?: base.ink,
    )
  }

  /** `#RRGGBB` or `#RRGGBBAA`. */
  private fun parseHex(hex: String): Color? {
    val clean = hex.trim().removePrefix("#")
    val v = clean.toLongOrNull(16) ?: return null
    return when (clean.length) {
      6 -> Color(0xFF000000 or v)
      8 -> Color(((v and 0xFF) shl 24) or (v ushr 8))
      else -> null
    }
  }

  override fun setUser(name: String?, email: String?) {
    main.post { DevReply.setUser(name, email) }
  }

  override fun setAttributes(attributes: ReadableMap) {
    val values = attributes.toHashMap()
    main.post { DevReply.setAttributes(values) }
  }

  override fun getUnreadCount(): Double = unread.toDouble()

  override fun setShowsUnreadBubble(shows: Boolean) {
    main.post { DevReply.showsUnreadBubble = shows }
  }

  override fun setLocale(tag: String?) {
    main.post { DevReply.setLocale(tag) }
  }

  override fun handle(url: String) {
    main.post { DevReply.handle(screen, android.net.Uri.parse(url)) }
  }

  override fun registerPushToken(token: String) {
    DevReply.registerPush(context, token)
  }

  override fun handleNotificationOpened(data: ReadableMap): Boolean {
    val values = data.toHashMap().mapValues { (_, v) -> v?.toString().orEmpty() }
    return DevReply.handleNotificationOpened(context.currentActivity ?: context, values)
  }

  override fun handlePush(data: ReadableMap): Boolean {
    val values = data.toHashMap().mapValues { (_, v) -> v?.toString().orEmpty() }
    return DevReply.handlePush(context, values)
  }

  override fun invalidate() {
    events?.cancel()
    scope.cancel()
    super.invalidate()
  }

  /** Sends `onUnreadChange` whenever the count changes (it's Compose state in the SDK). */
  private fun watchUnread() {
    if (watching != null) return
    watching = scope.launch {
      snapshotFlow { DevReply.unreadCount }.distinctUntilChanged().collect { count ->
        unread = count
        emitOnUnreadChange(Arguments.createMap().apply { putInt("count", count) })
      }
    }
  }

  companion object {
    const val NAME = NativeDevReplySpec.NAME
  }
}
