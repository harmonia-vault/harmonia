package org.harmoniavault.harmonia

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// 不依赖 Flutter 暂停时序；即使 Dart 尚未处理广播，恢复时也会消费锁屏标记。
class ScreenLock(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "harmonia/lock")
    private var pending = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) markLocked()
        }
    }

    init {
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED
        )
        channel.setMethodCallHandler { call, result ->
            if (call.method == "consumeLock") {
                val locked = isLocked()
                result.success(mapOf("locked" to locked, "wasLocked" to (pending || locked)))
                pending = false
            } else result.notImplemented()
        }
    }

    private fun isLocked(): Boolean =
        !context.getSystemService(PowerManager::class.java).isInteractive ||
            context.getSystemService(KeyguardManager::class.java).isKeyguardLocked

    private fun markLocked() {
        pending = true
        channel.invokeMethod("locked", null)
    }

    fun check() {
        if (isLocked()) markLocked()
    }

    fun close() {
        context.unregisterReceiver(receiver)
        channel.setMethodCallHandler(null)
    }
}
