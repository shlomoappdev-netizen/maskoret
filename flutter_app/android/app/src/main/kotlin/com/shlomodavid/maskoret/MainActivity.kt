package com.shlomodavid.maskoret

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Updates: hands a downloaded APK to the system installer (the user confirms there).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "maskoret/update").setMethodCallHandler { call, result ->
            if (call.method != "installApk") return@setMethodCallHandler result.notImplemented()
            val path = call.argument<String>("path") ?: return@setMethodCallHandler result.error("args", "no path", null)
            // Android asks once to allow installing apps from this app.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                return@setMethodCallHandler result.success("permission")
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            result.success("started")
        }
    }
}
