package org.harmoniavault.harmonia

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.print.HtmlPdf
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity 是 local_auth 的要求。平台通道提供：设备名、安装更新 APK、
// HTML 转 PDF、通过系统“保存到”保存文件、敏感内容复制（1 分钟后清空剪贴板）。
class MainActivity : FlutterFragmentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val clearClipboard = Runnable {
        val clipboard = getSystemService(ClipboardManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) clipboard.clearPrimaryClip()
        else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
    }

    private var pendingSave: Pair<ByteArray, MethodChannel.Result>? = null
    private val saveLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val (bytes, result) = pendingSave ?: return@registerForActivityResult
        pendingSave = null
        val uri = r.data?.data
        if (r.resultCode != RESULT_OK || uri == null) return@registerForActivityResult result.success(false)
        try {
            contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
            result.success(true)
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "harmonia/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceName" -> {
                    val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                    val model = Build.MODEL
                    result.success(if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model")
                }
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()
                )
                "openInstallSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                    )
                    result.success(null)
                }
                "install" -> {
                    val file = File(call.argument<String>("path")!!)
                    val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                    startActivity(
                        Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "htmlToPdf" -> HtmlPdf.render(this, call.argument<String>("html")!!) { bytes ->
                    if (bytes != null) result.success(bytes) else result.error("pdf_failed", null, null)
                }
                "saveFile" -> {
                    pendingSave?.second?.success(false)
                    pendingSave = call.argument<ByteArray>("bytes")!! to result
                    saveLauncher.launch(
                        Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType(call.argument<String>("mime")!!)
                            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name")!!)
                    )
                }
                "copySensitive" -> {
                    val clip = ClipData.newPlainText("Harmonia", call.argument<String>("text")!!)
                    // Android 13 起系统据此在剪贴板预览中隐藏内容；更早的版本忽略这个标记。
                    clip.description.extras = PersistableBundle().apply {
                        putBoolean(
                            if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE
                            else "android.content.extra.IS_SENSITIVE",
                            true,
                        )
                    }
                    getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                    handler.removeCallbacks(clearClipboard)
                    handler.postDelayed(clearClipboard, 60_000)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
