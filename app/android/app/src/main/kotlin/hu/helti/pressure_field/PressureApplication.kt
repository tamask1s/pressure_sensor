package hu.helti.pressure_field

import android.app.Application
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class PressureApplication : Application() {
    lateinit var engine: FlutterEngine
        private set

    override fun onCreate() {
        super.onCreate()
        engine = FlutterEngine(this)
        MethodChannel(engine.dartExecutor.binaryMessenger, "hu.helti.pressure_field/recording")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "sdk" -> result.success(android.os.Build.VERSION.SDK_INT)
                        "start" -> {
                            val intent = Intent(this, RecordingService::class.java)
                                .putExtra("location", call.argument<Boolean>("location") == true)
                            ContextCompat.startForegroundService(this, intent)
                            result.success(null)
                        }
                        "stop" -> { stopService(Intent(this, RecordingService::class.java)); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("recording", e.message, null) }
            }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }
}
