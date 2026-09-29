package com.devreply.reactnative

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.snapshotFlow
import com.devreply.sdk.DevReply
import com.devreply.sdk.DevReplyCategory
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
    }
  }

  override fun present(category: String?) {
    main.post {
      DevReply.present(screen, DevReplyCategory.entries.firstOrNull { it.name.equals(category, ignoreCase = true) })
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

  // Android push comes with FCM support in the SDK; nothing to do yet.
  override fun registerPushToken(hexToken: String) {}

  override fun invalidate() {
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
