package io.flutter.embedding.android

import android.content.Context
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener

// 绕过 Flutter 的已知问题 flutter/flutter#159670：FlutterView 不覆盖 onCheckIsTextEditor()，
// 密码管理器的填充弹窗关闭、窗口重新获得焦点时，系统判定窗口里没有输入框，随即收起输入法。
// 这里照 FlutterActivityAndFragmentDelegate.onCreateView 创建界面，只把 FlutterView 换成会如实
// 报告的子类。delegate 及其字段只对本包可见，所以文件放在该包下；升级 Flutter 时核对上游实现。
class EditorFlutterFragment : FlutterFragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        val delegate = delegate!!
        val context = requireContext()
        val view = if (renderMode == RenderMode.surface) {
            val surface = FlutterSurfaceView(context, transparencyMode == TransparencyMode.transparent)
            onFlutterSurfaceViewCreated(surface)
            EditorFlutterView(context, surface)
        } else {
            val texture = FlutterTextureView(context)
            texture.isOpaque = transparencyMode == TransparencyMode.opaque
            onFlutterTextureViewCreated(texture)
            EditorFlutterView(context, texture)
        }
        var displayed = false
        view.addOnFirstFrameRenderedListener(object : FlutterUiDisplayListener {
            override fun onFlutterUiDisplayed() {
                displayed = true
                this@EditorFlutterFragment.onFlutterUiDisplayed()
            }

            override fun onFlutterUiNoLongerDisplayed() {
                displayed = false
                this@EditorFlutterFragment.onFlutterUiNoLongerDisplayed()
            }
        })
        if (attachToEngineAutomatically()) view.attachToFlutterEngine(flutterEngine!!)
        view.id = FLUTTER_VIEW_ID
        delegate.flutterView = view
        // 第一帧画出前不绘制 Android 视图，保持启动画面；监听交给 delegate，界面销毁时由它移除。
        if (shouldDelayFirstAndroidViewDraw() && renderMode == RenderMode.surface) {
            val listener = object : ViewTreeObserver.OnPreDrawListener {
                override fun onPreDraw(): Boolean {
                    if (displayed) {
                        view.viewTreeObserver.removeOnPreDrawListener(this)
                        delegate.activePreDrawListener = null
                    }
                    return displayed
                }
            }
            delegate.activePreDrawListener = listener
            view.viewTreeObserver.addOnPreDrawListener(listener)
        }
        return view
    }
}

private class EditorFlutterView : FlutterView {
    constructor(context: Context, surface: FlutterSurfaceView) : super(context, surface)
    constructor(context: Context, texture: FlutterTextureView) : super(context, texture)

    // 输入法正显示着，说明 Flutter 里有输入框在输入；其余情况和原来一样报告“不是输入框”。
    override fun onCheckIsTextEditor(): Boolean =
        hasFocus() && ViewCompat.getRootWindowInsets(this)?.isVisible(WindowInsetsCompat.Type.ime()) == true
}
