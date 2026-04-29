package com.example.boox_tablet

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.boox_tablet/input"
    private val BT_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var btSocket: BluetoothSocket? = null
    private var btLocalServer: ServerSocket? = null

    // Keep reference to send "physicalEsc" / "physicalTab" back to Flutter
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPhysicalKeyboard" -> result.success(hasPhysicalKeyboard())

                "getPairedBluetoothDevices" -> {
                    try {
                        val adapter = BluetoothAdapter.getDefaultAdapter()
                        if (adapter == null) {
                            result.error("NO_BT", "No Bluetooth adapter", null)
                            return@setMethodCallHandler
                        }
                        val devices = adapter.bondedDevices.map { device ->
                            mapOf("name" to device.name, "address" to device.address)
                        }
                        result.success(devices)
                    } catch (e: SecurityException) {
                        result.error("PERMISSION", "Bluetooth permission denied", null)
                    }
                }

                "startBluetoothBridge" -> {
                    val address = call.argument<String>("address")
                        ?: return@setMethodCallHandler result.error("BAD_ARG", "Missing address", null)
                    val port = call.argument<Int>("port")
                        ?: return@setMethodCallHandler result.error("BAD_ARG", "Missing port", null)
                    Thread {
                        try {
                            startBluetoothBridge(address, port)
                            Handler(Looper.getMainLooper()).post { result.success(true) }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("BT_ERROR", e.message ?: "Unknown BT error", null)
                            }
                        }
                    }.start()
                }

                "stopBluetoothBridge" -> {
                    stopBluetoothBridge()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    // ── Key interception ───────────────────────────────────────────────────

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Call super first so Flutter always receives the raw event.
        val result = super.dispatchKeyEvent(event)
        // Prevent Android from consuming Tab (focus traversal) and
        // Escape (back navigation) after Flutter has already seen them.
        return when (event.keyCode) {
            KeyEvent.KEYCODE_TAB, KeyEvent.KEYCODE_ESCAPE -> true
            else -> result
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // KEYCODE_BACK (and sometimes KEYCODE_ESCAPE on some BOOX firmwares)
        // triggers onBackPressed instead of appearing as a keyboard event.
        // Forward it to Flutter as a synthetic ESC so the app can send it to PC.
        val ch = methodChannel
        if (ch != null) {
            ch.invokeMethod("physicalEsc", null)
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    // ── Bluetooth bridge ───────────────────────────────────────────────────

    private fun startBluetoothBridge(address: String, port: Int) {
        stopBluetoothBridge()
        val adapter = BluetoothAdapter.getDefaultAdapter()
            ?: throw Exception("No Bluetooth adapter")
        adapter.cancelDiscovery()

        val device = adapter.getRemoteDevice(address)
        val socket = device.createRfcommSocketToServiceRecord(BT_UUID)
        socket.connect()
        btSocket = socket

        val server = ServerSocket(port, 1, InetAddress.getByName("127.0.0.1"))
        btLocalServer = server

        Thread {
            try {
                val tcpClient = server.accept()
                val btIn: InputStream = socket.inputStream
                val btOut: OutputStream = socket.outputStream
                val tcpIn: InputStream = tcpClient.getInputStream()
                val tcpOut: OutputStream = tcpClient.getOutputStream()

                val fwdBtToTcp = Thread {
                    try { btIn.copyTo(tcpOut) } catch (_: Exception) {}
                }
                val fwdTcpToBt = Thread {
                    try { tcpIn.copyTo(btOut) } catch (_: Exception) {}
                }
                fwdBtToTcp.start()
                fwdTcpToBt.start()
                fwdBtToTcp.join()
                fwdTcpToBt.join()
            } catch (_: Exception) {}
        }.start()
    }

    private fun stopBluetoothBridge() {
        try { btSocket?.close() } catch (_: Exception) {}
        try { btLocalServer?.close() } catch (_: Exception) {}
        btSocket = null
        btLocalServer = null
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private fun hasPhysicalKeyboard(): Boolean {
        val ids = InputDevice.getDeviceIds()
        return ids.any { id ->
            val dev = InputDevice.getDevice(id) ?: return@any false
            (dev.sources and InputDevice.SOURCE_KEYBOARD) == InputDevice.SOURCE_KEYBOARD &&
            dev.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
        }
    }
}
