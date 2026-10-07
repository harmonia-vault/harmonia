package android.print

import android.content.Context
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.File

// 用系统 WebView 把 HTML 排版成 A4 PDF。LayoutResultCallback / WriteResultCallback 的构造函数
// 只对 android.print 包可见，所以这个文件放在该包下。
object HtmlPdf {
    // 转换期间持有 WebView，防止被回收。
    private var web: WebView? = null

    fun render(context: Context, html: String, done: (ByteArray?) -> Unit) {
        val view = WebView(context)
        web = view
        fun finish(bytes: ByteArray?) {
            web = null
            done(bytes)
        }
        view.webViewClient = object : WebViewClient() {
            override fun onPageFinished(v: WebView, url: String?) {
                val adapter = v.createPrintDocumentAdapter("harmonia")
                val attributes = PrintAttributes.Builder()
                    .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                    .setResolution(PrintAttributes.Resolution("pdf", "pdf", 600, 600))
                    .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                    .build()
                val file = File.createTempFile("sheet", ".pdf", context.cacheDir)
                adapter.onLayout(null, attributes, null, object : PrintDocumentAdapter.LayoutResultCallback() {
                    override fun onLayoutFinished(info: PrintDocumentInfo, changed: Boolean) {
                        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_WRITE)
                        adapter.onWrite(arrayOf(PageRange.ALL_PAGES), fd, CancellationSignal(),
                            object : PrintDocumentAdapter.WriteResultCallback() {
                                override fun onWriteFinished(pages: Array<PageRange>) {
                                    fd.close()
                                    val bytes = file.readBytes()
                                    file.delete()
                                    finish(bytes)
                                }

                                override fun onWriteFailed(error: CharSequence?) {
                                    fd.close()
                                    file.delete()
                                    finish(null)
                                }
                            })
                    }

                    override fun onLayoutFailed(error: CharSequence?) {
                        file.delete()
                        finish(null)
                    }
                }, null)
            }
        }
        view.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
    }
}
