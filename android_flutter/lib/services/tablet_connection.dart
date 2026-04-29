import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/pen_event.dart';

enum TransportType { wifi, usb, bluetooth }
enum ConnState { disconnected, connecting, connected, error }

/// Manages two TCP connections to the Windows PC:
/// 1. Control channel: sends pen events (JSON)
/// 2. Video channel: receives screen frames (JPEG)
class TabletConnection extends ChangeNotifier {
  // ── Transport config ────────────────────────────────────────────────
  TransportType _transportType = TransportType.wifi;
  String _host = '192.168.1.100';
  int _controlPort = 52017;
  int _videoPort = 52018;
  String _errorMessage = '';

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
  final List<int> _frameSizes = [];

  // ── PC screen info ──────────────────────────────────────────────────
  int _pcScreenWidth = 1920;
  int _pcScreenHeight = 1080;
  String _ctrlBuffer = '';

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
  int get frameCount => _frameCount;
  int get pcScreenWidth => _pcScreenWidth;
  int get pcScreenHeight => _pcScreenHeight;

  void setTransport(TransportType type) {
    if (_state == ConnState.connected) return;
    _transportType = type;
    notifyListeners();
  }

  void setHost(String host) => _host = host;
  void setControlPort(int port) => _controlPort = port;
  void setVideoPort(int port) => _videoPort = port;

  // ── Connect ─────────────────────────────────────────────────────────
  Future<bool> connect() async {
    _state = ConnState.connecting;
    _errorMessage = '';
    notifyListeners();

    final host = _transportType == TransportType.usb ? '127.0.0.1' : _host;

    try {
      // 1. Connect control channel
      _ctrlSocket = await Socket.connect(
        host,
        _controlPort,
        timeout: const Duration(seconds: 5),
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
          debugPrint('Control closed');
          disconnect();
        },
        cancelOnError: false,
      );

      _state = ConnState.connected;
      notifyListeners();

      // 2. Connect video channel (optional)
      _connectVideo(host);
      return true;
    } on SocketException catch (e) {
      _state = ConnState.error;
      _errorMessage = 'Cannot connect to $host:$_controlPort — ${e.message}';
      notifyListeners();
      return false;
    }
  }

  void _handleControlMessage(String line) {
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      if (msg['type'] == 'screen_info') {
        _pcScreenWidth = (msg['width'] as num).toInt();
        _pcScreenHeight = (msg['height'] as num).toInt();
        notifyListeners();
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

  void _processVideoData(Uint8List data) {
    _videoBuffer.addAll(data);

    while (true) {
      if (_expectedFrameSize == 0) {
        // Need at least 4 bytes for header
        if (_videoBuffer.length < 4) break;

        // Read 4-byte LE frame size
        _expectedFrameSize =
            _videoBuffer[0] |
            (_videoBuffer[1] << 8) |
            (_videoBuffer[2] << 16) |
            (_videoBuffer[3] << 24);
        _videoBuffer.removeRange(0, 4);
      }

      // Need N bytes for frame
      if (_videoBuffer.length < _expectedFrameSize) break;

      // Complete frame
      _latestFrame = Uint8List.fromList(
        _videoBuffer.sublist(0, _expectedFrameSize),
      );
      _videoBuffer.removeRange(0, _expectedFrameSize);
      _expectedFrameSize = 0;
      _frameCount++;
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

  // ── Send key event ───────────────────────────────────────────────────
  void sendKey(Map<String, dynamic> event) {
    if (!isConnected) return;
    try {
      _ctrlSocket!.write('${jsonEncode(event)}\n');
    } catch (e) {
      debugPrint('SendKey error: $e');
    }
  }

  // ── Disconnect ──────────────────────────────────────────────────────
  void disconnect() {
    _videoSubscription?.cancel();
    _videoSocket?.destroy();
    _videoSocket = null;
    _videoConnected = false;

    _ctrlSubscription?.cancel();
    _ctrlSocket?.destroy();
    _ctrlSocket = null;

    _expectedFrameSize = 0;
    _videoBuffer.clear();
    _state = ConnState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
