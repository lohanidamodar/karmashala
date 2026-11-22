package com.popupbits.karmashala

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Names the package that installed this app — "com.android.vending" for
// Google Play — so a Play install keeps Play's update flow and an APK
// installed by hand is offered the GitHub release instead. Null when Android
// names no installer (adb, or a package it does not record).
object InstallSourceChannel {
    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, "karmashala/install_source")
            .setMethodCallHandler { call, result ->
                if (call.method != "installer") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    result.success(installer(context))
                } catch (error: Exception) {
                    result.error("unavailable", error.message, null)
                }
            }
    }

    private fun installer(context: Context): String? {
        val packages = context.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packages.getInstallSourceInfo(context.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            packages.getInstallerPackageName(context.packageName)
        }
    }
}
