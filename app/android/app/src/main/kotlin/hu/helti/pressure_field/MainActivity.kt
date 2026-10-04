package hu.helti.pressure_field

import io.flutter.embedding.android.FlutterActivity
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import java.io.File

class MainActivity : FlutterActivity() {
    private var exportResult: MethodChannel.Result? = null
    private var exportFile: File? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hu.helti.pressure_field/export")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
                if (exportResult != null) { result.error("busy", "Már folyamatban van mentés.", null); return@setMethodCallHandler }
                val source = File(call.argument<String>("path") ?: "").canonicalFile
                if (!source.path.startsWith(cacheDir.canonicalPath + File.separator)) { result.error("path", "Érvénytelen exportfájl.", null); return@setMethodCallHandler }
                exportFile = source; exportResult = result
                try {
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE); type = "text/csv"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "meres.csv")
                    }, 241)
                } catch (e: Exception) { exportResult = null; exportFile = null; result.error("save", e.message, null) }
            }
    }
    @Deprecated("Android activity result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 241) return
        val result = exportResult ?: return; val source = exportFile
        exportResult = null; exportFile = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || source == null) { result.success(false); return }
        Thread {
            try { contentResolver.openOutputStream(uri, "w")!!.use { out -> source.inputStream().use { it.copyTo(out) } }; runOnUiThread { result.success(true) } }
            catch (e: Exception) { runOnUiThread { result.error("save", e.message, null) } }
        }.start()
    }
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as PressureApplication).engine
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
