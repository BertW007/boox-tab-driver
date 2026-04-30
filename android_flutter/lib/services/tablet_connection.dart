import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/pen_event.dart';

enum TransportType { wifi, usb, bluetooth }
enum ConnState { disconnected, connecting, connected, error }

/// Manages two TCP connections to the Windows PC:
/// 1. Control channel: sends pen events (JSON)
/// 2. Video channel: receives screen frames (JPEG)
class TabletConnection extends ChangeNotifier {
  static const _channel = MethodChannel('com.example.boox_tablet/input');

  // ── Transport config ────────────────────────────────────────────────
  TransportType _transportType = TransportType.wifi;
  String _host = '192.168.1.100';
  int _controlPort = 52017;
  int _videoPort = 52018;
  String _errorMessage = '';
  String _btDeviceAddress = '';
  bool _videoEnabled = true;

  // ── Control socket ──────────────────────────────────────────────────
  Socket? _ctrlSocket;
  StreamSubscription? _ctrlSubscription;

  // ── Video socket ────────────────────────────────────────────────────
  Socket? _videoSocket;
  StreamSubscription? _videoSubscription;

  // ── State ───────────────────────────────────────────────────────────
  ConnState _state = ConnState.disconnected;
  bool _videoConnected = false;

  // ── Frame data ──────────────────────────────────────────────────────
  Uint8List? _latestFrame;
  int _frameCount = 0;

  // ── Transfer stats ───────────────────────────────────────────────────
  int _totalVideoBytes = 0;
  int _totalCtrlBytes  = 0;
  int _framesLastSec   = 0;
  int _bytesLastSec    = 0;
  int _fpsNow          = 0;
  int _bpsNow          = 0;
  DateTime _statsWindow = DateTime.now();
  Timer? _statsTimer;

  // ── PC screen / connection info ─────────────────────────────────────
  int _pcScreenWidth = 1920;
  int _pcScreenHeight = 1080;
  String _connectedPcName = '';
  String _ctrlBuffer = '';
  String _cursorShape = 'arrow';
  bool _capsLock = false;
  bool _numLock = false;
  bool _scrollLock = false;

  // ── Auto-reconnect ──────────────────────────────────────────────────
  bool _intentionalDisconnect = false;
  bool _autoReconnect = true;
  int _reconnectAttempt = 0;
  static const _maxReconnectAttempts = 8;
  // Progressive delays: 2s, 3s, 5s, 8s, 12s, 18s, 25s, 35s
  static const _reconnectDelays = [2, 3, 5, 8, 12, 18, 25, 35];
  Timer? _reconnectTimer;
  String _reconnectStatus = '';

  // ── Getters ─────────────────────────────────────────────────────────
  TransportType get transportType => _transportType;
  ConnState get state => _state;
  String get errorMessage => _errorMessage;
  bool get isConnected => _state == ConnState.connected;
  bool get isVideoConnected => _videoConnected;
  String get host => _host;
  int get controlPort => _controlPort;
  int get videoPort => _videoPort;
  Uint8List? get latestFrame => _latestFrame;
  int get frameCount      => _frameCount;
  int get totalVideoBytes => _totalVideoBytes;
  int get totalCtrlBytes  => _totalCtrlBytes;
  int get fpsNow          => _fpsNow;
  int get bpsNow          => _bpsNow;
  int get pcScreenWidth => _pcScreenWidth;
  int get pcScreenHeight => _pcScreenHeight;
  String get connectedPcName => _connectedPcName;
  String get cursorShape => _cursorShape;
  bool get capsLock => _capsLock;
  bool get numLock => _numLock;
  bool get scrollLock => _scrollLock;
  bool get isReconnecting => _reconnectTimer?.isActive == true;
  String get reconnectStatus => _reconnectStatus;
  bool get videoEnabled => _videoEnabled;

  void setTransport(TransportType type) {
    if (_state == ConnState.connected) return;
    _transportType = type;
    notifyListeners();
  }

  void setHost(String host) => _host = host;
  void setControlPort(int port) => _controlPort = port;
  void setVideoPort(int port) => _videoPort = port;
  void setBtDevice(String address) => _btDeviceAddress = address;
  void setAutoReconnect(bool value) => _autoReconnect = value;
  void setVideoEnabled(bool value) => _videoEnabled = value;

  Future<void> enableVideo() async {
    if (!isConnected || _videoConnected) return;
    _videoEnabled = true;
    final host = switch (_transportType) {
      TransportType.wifi => _host,
      TransportType.usb || TransportType.bluetooth => '127.0.0.1',
    };
    await _connectVideo(host);
  }

  void disableVideo() {
    _videoEnabled = false;
    _videoSubscription?.cancel();
    _videoSocket?.destroy();
    _videoSocket = null;
    _videoConnected = false;
    _latestFrame = null;
    _videoBuffer.clear();
    _expectedFrameSize = 0;
    notifyListeners();
  }

  // ── Connect ─────────────────────────────────────────────────────────
  Future<bool> connect() async {
    _reconnectTimer?.cancel();
    _intentionalDisconnect = false;
    _state = ConnState.connecting;
    _errorMessage = '';
    _reconnectStatus = '';
    _connectedPcName = '';
    notifyListeners();

    String host;
    switch (_transportType) {
      case TransportType.usb:
        host = '127.0.0.1';
      case TransportType.bluetooth:
        host = '127.0.0.1';
        try {
          await _channel.invokeMethod('startBluetoothBridge', {
            'address': _btDeviceAddress,
            'port': _controlPort,
          });
        } catch (e) {
          _state = ConnState.error;
          _errorMessage = 'Bluetooth: $e';
          notifyListeners();
          return false;
        }
      case TransportType.wifi:
        host = _host;
    }

    try {
      _ctrlSocket = await Socket.connect(
        host,
        _controlPort,
        timeout: const Duration(seconds: 8),
      );
      debugPrint('Control connected to $host:$_controlPort');

      _ctrlSubscription = _ctrlSocket!.listen(
        (data) {
          _ctrlBuffer += utf8.decode(data);
          final lines = _ctrlBuffer.split('\n');
          _ctrlBuffer = lines.last;
          for (int i = 0; i < lines.length - 1; i++) {
            final line = lines[i].trim();
            if (line.isEmpty) continue;
            _handleControlMessage(line);
          }
        },
        onError: (e) => debugPrint('Control error: $e'),
        onDone: () {
          debugPrint('Control closed unexpectedly');
          final wasIntentional = _intentionalDisconnect;
          _disconnectSockets();
          if (!wasIntentional && _autoReconnect) {
            _scheduleReconnect();
          }
        },
        cancelOnError: false,
      );

      _state = ConnState.connected;
      _reconnectAttempt = 0;
      _totalVideoBytes = 0;
      _totalCtrlBytes  = 0;
      _frameCount      = 0;
      _framesLastSec   = 0;
      _bytesLastSec    = 0;
      _statsWindow     = DateTime.now();
      _statsTimer?.cancel();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateStats());
      notifyListeners();

      if (_videoEnabled) {
        _connectVideo(host);
      }
      return true;
    } on SocketException catch (e) {
      _state = ConnState.error;
      _errorMessage = 'Cannot connect to $host:$_controlPort — ${e.message}';
      if (_transportType == TransportType.bluetooth) {
        await _channel.invokeMethod('stopBluetoothBridge').catchError((_) {});
      }
      notifyListeners();
      if (!_intentionalDisconnect && _autoReconnect) {
        _scheduleReconnect();
      }
      return false;
    }
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      _reconnectStatus = 'Nie udało się połączyć po $_maxReconnectAttempts próbach';
      _state = ConnState.error;
      notifyListeners();
      return;
    }

    final delaySec = _reconnectDelays[_reconnectAttempt.clamp(0, _reconnectDelays.length - 1)];
    _reconnectAttempt++;
    _state = ConnState.disconnected;
    _reconnectStatus = 'Próba $_reconnectAttempt/$_maxReconnectAttempts za ${delaySec}s…';
    notifyListeners();

    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (!_intentionalDisconnect) connect();
    });
  }

  void _handleControlMessage(String line) {
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      if (msg['type'] == 'screen_info') {
        _pcScreenWidth = (msg['width'] as num).toInt();
        _pcScreenHeight = (msg['height'] as num).toInt();
        _connectedPcName = msg['hostname'] as String? ?? '';
        notifyListeners();
      } else if (msg['type'] == 'cursor') {
        final shape = msg['shape'] as String? ?? 'arrow';
        if (shape != _cursorShape) {
          _cursorShape = shape;
          notifyListeners();
        }
      } else if (msg['type'] == 'led') {
        final caps   = msg['caps']   as bool? ?? _capsLock;
        final num    = msg['num']    as bool? ?? _numLock;
        final scroll = msg['scroll'] as bool? ?? _scrollLock;
        if (caps != _capsLock || num != _numLock || scroll != _scrollLock) {
          _capsLock = caps; _numLock = num; _scrollLock = scroll;
          notifyListeners();
        }
      }
    } catch (_) {
      debugPrint('Control msg: $line');
    }
  }

  Future<void> _connectVideo(String host) async {
    try {
      _videoSocket = await Socket.connect(
        host,
        _videoPort,
        timeout: const Duration(seconds: 3),
      );
      debugPrint('Video connected to $host:$_videoPort');
      _videoConnected = true;
      notifyListeners();
      _readVideoFrames();
    } catch (e) {
      debugPrint('Video connection failed (optional): $e');
      _videoConnected = false;
    }
  }

  // ── Video frame parsing ────────────────────────────────────────────
  // Protocol: [4 bytes LE frame size][JPEG data]
  final List<int> _videoBuffer = [];
  int _expectedFrameSize = 0;

  void _readVideoFrames() {
    _videoBuffer.clear();
    _expectedFrameSize = 0;

    _videoSubscription = _videoSocket!.listen(
      (data) => _processVideoData(data),
      onError: (e) {
        debugPrint('Video error: $e');
        _videoConnected = false;
        notifyListeners();
      },
      onDone: () {
        debugPrint('Video closed');
        _videoConnected = false;
        notifyListeners();
      },
      cancelOnError: false,
    );
  }

  void _updateStats() {
    _fpsNow        = _framesLastSec;
    _bpsNow        = _bytesLastSec;
    _framesLastSec = 0;
    _bytesLastSec  = 0;
    notifyListeners();
  }

  void _processVideoData(Uint8List data) {
    _totalVideoBytes += data.length;
    _bytesLastSec    += data.length;
    _videoBuffer.addAll(data);

    while (true) {
      if (_expectedFrameSize == 0) {
        if (_videoBuffer.length < 4) break;
        _expectedFrameSize =
            _videoBuffer[0] |
            (_videoBuffer[1] << 8) |
            (_videoBuffer[2] << 16) |
            (_videoBuffer[3] << 24);
        _videoBuffer.removeRange(0, 4);
      }

      if (_videoBuffer.length < _expectedFrameSize) break;

      _latestFrame = Uint8List.fromList(_videoBuffer.sublist(0, _expectedFrameSize));
      _videoBuffer.removeRange(0, _expectedFrameSize);
      _expectedFrameSize = 0;
      _frameCount++;
      _framesLastSec++;
      notifyListeners();
    }
  }

  // ── Send pen event ──────────────────────────────────────────────────
  void send(PenEvent event) {
    if (!isConnected) return;
    try {
      _ctrlSocket!.write('${jsonEncode(event.toJson())}\n');
    } catch (e) {
      debugPrint('Send error: $e');
    }
  }

  // ── Release all held keys/buttons ───────────────────────────────────
  void sendReleaseAll() {
    if (!isConnected) return;
    try {
      _ctrlSocket!.write('${jsonEncode({'type': 'release_all'})}\n');
    } catch (_) {}
  }

  // ── Send shortcut ────────────────────────────────────────────────────
  void sendShortcut(String name) {
    if (!isConnected) return;
    try {
      _ctrlSocket!.write('${jsonEncode({'type': 'shortcut', 'name': name})}\n');
    } catch (e) {
      debugPrint('SendShortcut error: $e');
    }
  }

  // ── Send key event ───────────────────────────────────────────────────
  void sendKey(Map<String, dynamic> event) {
    if (!isConnected) return;
    try {
      _ctrlSocket!.write('${jsonEncode(event)}\n');
    } catch (e) {
      debugPrint('SendKey error: $e');
    }
  }

  // ── Disconnect (intentional) ─────────────────────────────────────────
  void disconnect() {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _reconnectStatus = '';
    _disconnectSockets();
  }

  void _disconnectSockets() {
    _videoSubscription?.cancel();
    _videoSocket?.destroy();
    _videoSocket = null;
    _videoConnected = false;

    _ctrlSubscription?.cancel();
    _ctrlSocket?.destroy();
    _ctrlSocket = null;

    if (_transportType == TransportType.bluetooth) {
      _channel.invokeMethod('stopBluetoothBridge').catchError((_) {});
    }

    _expectedFrameSize = 0;
    _videoBuffer.clear();
    _connectedPcName = '';
    _state = ConnState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    disconnect();
    super.dispose();
  }
}
