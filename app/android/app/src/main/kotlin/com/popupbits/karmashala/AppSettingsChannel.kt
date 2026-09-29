package com.popupbits.karmashala

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Opens this app's page in the system settings, where a permission refused
// for good (the camera, notifications) is turned back on.
object AppSettingsChannel {
    fun register(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, "karmashala/app_settings")
            .setMethodCallHandler { call, result ->
                if (call.method != "open") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", activity.packageName, null),
                )
                try {
                    activity.startActivity(intent)
                    result.success(true)
                } catch (_: ActivityNotFoundException) {
                    result.success(false)
                }
            }
    }
}
