package com.devreply.reactnative

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.snapshotFlow
import com.devreply.sdk.DevReply
import com.devreply.sdk.DevReplyCategory
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

// The React Native bridge: every call goes to the native DevReply SDK, on the main thread.
class DevReplyModule : Module() {
  private val main = Handler(Looper.getMainLooper())
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private var watching: Job? = null
  @Volatile private var unread = 0

  override fun definition() = ModuleDefinition {
    Name("DevReply")
    Events("onUnreadChange")

    Function("configure") { publicKey: String ->
      main.post {
        // The current screen if there is one: the unread bubble then shows on it straight away.
        val context = appContext.currentActivity ?: appContext.reactContext ?: return@post
        DevReply.configure(context, publicKey)
        watchUnread()
      }
    }

    Function("present") { category: String? ->
      main.post {
        val context = appContext.currentActivity ?: appContext.reactContext ?: return@post
        DevReply.present(context, DevReplyCategory.entries.firstOrNull { it.name.equals(category, ignoreCase = true) })
      }
    }

    Function("setUser") { name: String?, email: String? ->
      main.post { DevReply.setUser(name, email) }
    }

    Function("setAttributes") { attributes: Map<String, Any?> ->
      main.post { DevReply.setAttributes(attributes) }
    }

    Function("getUnreadCount") { unread }

    Function("setShowsUnreadBubble") { shows: Boolean ->
      main.post { DevReply.showsUnreadBubble = shows }
    }

    // Android push comes with FCM support in the SDK; nothing to do yet.
    Function("registerPushToken") { _: String -> }

    OnDestroy { scope.cancel() }
  }

  /** Sends `onUnreadChange` whenever the count changes (it's Compose state in the SDK). */
  private fun watchUnread() {
    if (watching != null) return
    watching = scope.launch {
      snapshotFlow { DevReply.unreadCount }.distinctUntilChanged().collect { count ->
        unread = count
        sendEvent("onUnreadChange", mapOf("count" to count))
      }
    }
  }
}
