package org.harmoniavault.harmonia

import android.app.Activity
import android.os.Build
import android.view.ViewTreeObserver
import io.flutter.plugin.common.EventChannel

// 折叠区域由 Flutter 引擎传递；这里只补充分屏窗口所在的物理边缘。
class WindowLayoutChannel(private val activity: Activity) : EventChannel.StreamHandler, ViewTreeObserver.OnGlobalLayoutListener {
    private var sink: EventChannel.EventSink? = null
    private var previous: Map<String, Any?>? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        previous = null
        activity.window.decorView.viewTreeObserver.addOnGlobalLayoutListener(this)
        onGlobalLayout()
    }

    override fun onCancel(arguments: Any?) {
        activity.window.decorView.viewTreeObserver.removeOnGlobalLayoutListener(this)
        sink = null
    }

    override fun onGlobalLayout() {
        var edge: String? = null
        if (Build.VERSION.SDK_INT >= 30 && activity.isInMultiWindowMode) {
            val window = activity.windowManager.currentWindowMetrics.bounds
            val display = activity.windowManager.maximumWindowMetrics.bounds
            if (window.width() < display.width()) {
                edge = if (window.centerX() < display.centerX()) "left" else "right"
            }
        }
        val data = mapOf("edge" to edge, "occlusions" to emptyList<List<Double>>())
        if (data != previous) {
            previous = data
            sink?.success(data)
        }
    }
}
