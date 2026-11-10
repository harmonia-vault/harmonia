package org.harmoniavault.harmonia

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 后台通知（设计文档 18.4）：通知权限、FCM 令牌、通知渠道“批准请求”，以及“用户点开了通知”。
// 通知由 FCM 在 App 不在前台时直接显示，App 在前台时不显示。Firebase 的配置在构建时由 dart-define 写进资源
// （见 build.gradle.kts）；没有配置的构建不会初始化 Firebase，按“收不到”处理。
class PushChannel(private val activity: FlutterFragmentActivity) {
    companion object {
        const val CHANNEL_ID = "approvals"
        private const val PREFS = "harmonia_push"
        private const val ASKED = "permission_requested"
    }

    private var opened = false
    private var pendingPermission: MethodChannel.Result? = null
    private val permissionLauncher =
        activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            pendingPermission?.success(granted && enabled())
            pendingPermission = null
        }

    private val prefs get() = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 通知渠道要在第一条通知到达前建好，FCM 按消息里的 channel_id 显示。 */
    fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(CHANNEL_ID, "批准请求", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "电脑或新设备请求批准时提醒你"
        }
        activity.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    /** 点开 FCM 通知启动的 Intent 带着消息的附加字段。读到后去掉，免得重建页面时重复计算。 */
    fun onIntent(intent: Intent?) {
        val extras = intent?.extras ?: return
        if (extras.containsKey("google.message_id")) {
            opened = true
            intent.removeExtra("google.message_id")
        }
    }

    private fun enabled(): Boolean {
        val manager = NotificationManagerCompat.from(activity)
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: return true
        return channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun needsRuntimePermission() =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permission" -> result.success(
                when {
                    enabled() -> "granted"
                    needsRuntimePermission() && !prefs.getBoolean(ASKED, false) -> "notDetermined"
                    else -> "denied"
                }
            )
            "requestPermission" -> {
                if (!needsRuntimePermission()) return result.success(enabled())
                prefs.edit().putBoolean(ASKED, true).apply()
                pendingPermission?.success(false)
                pendingPermission = result
                permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
            "token" -> {
                if (FirebaseApp.getApps(activity).isEmpty()) return result.success(null)
                FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                    val token = if (task.isSuccessful) task.result else null
                    result.success(token?.let { mapOf("token" to it) })
                }
            }
            "openSettings" -> {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
                }
                activity.startActivity(intent)
                result.success(null)
            }
            "takeOpened" -> {
                result.success(opened)
                opened = false
            }
            else -> result.notImplemented()
        }
    }
}
