package com.popupbits.karmashala

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Two native duties, each on a channel rather than a plugin: hold a
// WifiManager.MulticastLock while Dart's LAN discovery listens for the
// server's beacon (Android drops multicast datagrams without one), and report
// the default network changing, so a link on a dead socket is resumed at once
// rather than after its keepalive gives up.
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "karmashala/multicast_lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "release" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        AppSettingsChannel.register(messenger, this)
        EventChannel(messenger, "karmashala/network")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    watchNetwork(events)
                }

                override fun onCancel(arguments: Any?) {
                    unwatchNetwork()
                }
            })
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("karmashala").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.takeIf { it.isHeld }?.release()
        multicastLock = null
    }

    // One event per default network: its id, or "none" when there is none.
    // The callbacks run on a connectivity thread; the sink wants the main one.
    private fun watchNetwork(events: EventChannel.EventSink) {
        unwatchNetwork()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val connectivity =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return
        val main = Handler(Looper.getMainLooper())
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post { events.success(network.toString()) }
            }

            override fun onLost(network: Network) {
                main.post { events.success("none") }
            }
        }
        try {
            connectivity.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (error: RuntimeException) {
            events.error("unavailable", error.message, null)
        }
    }

    private fun unwatchNetwork() {
        val callback = networkCallback ?: return
        networkCallback = null
        val connectivity =
            applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        try {
            connectivity?.unregisterNetworkCallback(callback)
        } catch (_: IllegalArgumentException) {
            // Never registered, or already gone.
        }
    }

    override fun onDestroy() {
        unwatchNetwork()
        releaseMulticastLock()
        super.onDestroy()
    }
}
