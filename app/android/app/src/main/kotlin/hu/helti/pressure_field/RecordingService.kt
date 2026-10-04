package hu.helti.pressure_field

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*

class RecordingService : Service() {
    private var wake: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("measurement", "Folyamatban lévő mérés", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, "measurement")
            .setSmallIcon(R.drawable.ic_measurement).setContentTitle("Talajnyomás · mérés folyamatban")
            .setContentText("A nyomásadatok rögzülnek. Megnyitás a leállításhoz.")
            .setContentIntent(open).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).build()
        if (Build.VERSION.SDK_INT >= 29) {
            val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                (if (intent?.getBooleanExtra("location", false) == true) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0)
            startForeground(21, notification, type)
        } else startForeground(21, notification)
        if (wake == null) {
            wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pressure:recording")
            wake!!.acquire()
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        wake?.let { if (it.isHeld) it.release() }; wake = null
        super.onDestroy()
    }
}
