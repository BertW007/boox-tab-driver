package com.example.boox_tablet

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
    private val REQ_BT = 1001

    private var btSocket: BluetoothSocket? = null
    private var btLocalServer: ServerSocket? = null
    private var methodChannel: MethodChannel? = null

    // Pending MethodChannel result waiting for runtime permission grant
    private var pendingBtResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPhysicalKeyboard" -> result.success(hasPhysicalKeyboard())

                "getPairedBluetoothDevices" -> {
                    if (!hasBtPermission()) {
                        pendingBtResult = result
                        requestBtPermissions()
                    } else {
                        result.success(pairedDevices())
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

    // ── Runtime Bluetooth permissions (Android 12+) ────────────────────────

    private fun hasBtPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun requestBtPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN),
                REQ_BT
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_BT) {
            val r = pendingBtResult ?: return
            pendingBtResult = null
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                r.success(pairedDevices())
            } else {
                r.error("PERMISSION", "Bluetooth permission denied by user", null)
            }
        }
    }

    private fun pairedDevices(): List<Map<String, String>> {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return emptyList()
        return adapter.bondedDevices.map { mapOf("name" to it.name, "address" to it.address) }
    }

    // ── Key interception ───────────────────────────────────────────────────

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
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
        // KEYCODE_BACK (or KEYCODE_ESCAPE on some BOOX firmwares) triggers
        // onBackPressed instead of a keyboard event — forward to Flutter as ESC.
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

                val fwdBtToTcp = Thread { try { btIn.copyTo(tcpOut)  } catch (_: Exception) {} }
                val fwdTcpToBt = Thread { try { tcpIn.copyTo(btOut)  } catch (_: Exception) {} }
                fwdBtToTcp.start(); fwdTcpToBt.start()
                fwdBtToTcp.join();  fwdTcpToBt.join()
            } catch (_: Exception) {}
        }.start()
    }

    private fun stopBluetoothBridge() {
        try { btSocket?.close()      } catch (_: Exception) {}
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
