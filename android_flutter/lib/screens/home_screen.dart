import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/pen_event.dart';
import '../services/tablet_connection.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ipController = TextEditingController(text: '192.168.0.22');
  final _portController = TextEditingController(text: '52017');
  final _videoPortController = TextEditingController(text: '52018');
  final _connection = TabletConnection();

  final List<_StrokePoint> _currentStroke = [];
  final List<_TimedStroke> _completedStrokes = [];
  Timer? _fadeTimer;

  bool _invertColors = false;
  bool _fillScreen = false;
  bool _softKbVisible = false;
  bool _physicalKbConnected = false;
  final _softKbController = TextEditingController();
  final _softKbFocus = FocusNode();
  String _prevSoftKbText = '';

  bool _videoEnabled = true;
  bool _touchLocked = false;
  Offset? _hoverPos;
  String _tabletIp = '';

  // Bluetooth device selection
  List<Map<String, String>> _btDevices = [];
  String? _selectedBtAddress;
  String _selectedBtName = '';

  static const _inputChannel = MethodChannel('com.example.boox_tablet/input');

  @override
  void initState() {
    super.initState();
    _connection.addListener(_onStateChanged);
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_completedStrokes.isEmpty) return;
      setState(() {
        _completedStrokes.removeWhere((s) => s.isDead);
      });
    });
    _checkPhysicalKeyboard();

    // Global hardware keyboard handler — fires regardless of which widget has focus.
    // This is the most reliable path for physical keyboards on BOOX.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);

    // Fallback: ESC/back button forwarded from Kotlin via onBackPressed
    _inputChannel.setMethodCallHandler((call) async {
      if (call.method == 'physicalEsc' && _connection.isConnected) {
        _connection.sendKey({'type': 'key', 'action': 'down', 'char': '', 'label': 'Escape', 'logical': 0x10000001b});
        _connection.sendKey({'type': 'key', 'action': 'up',   'char': '', 'label': 'Escape', 'logical': 0x10000001b});
      }
    });
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!_connection.isConnected) return false;
    _handleKeyEvent(event);
    return false;
  }

  Future<void> _fetchTabletIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('wlan') || name.contains('wifi') || name.contains('eth')) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback) {
              if (mounted) setState(() => _tabletIp = addr.address);
              return;
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _checkPhysicalKeyboard() async {
    try {
      final result = await _inputChannel.invokeMethod<bool>('hasPhysicalKeyboard');
      if (mounted) setState(() => _physicalKbConnected = result ?? false);
    } catch (_) {
      _physicalKbConnected = false;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _fadeTimer?.cancel();
    _connection.removeListener(_onStateChanged);
    _connection.dispose();
    _ipController.dispose();
    _portController.dispose();
    _videoPortController.dispose();
    _softKbController.dispose();
    _softKbFocus.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    if (_connection.isConnected) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _fetchTabletIp();
      _checkPhysicalKeyboard().then((_) {
        if (!_physicalKbConnected && mounted) {
          setState(() => _softKbVisible = true);
          _softKbFocus.requestFocus();
        }
      });
    } else {
      setState(() => _softKbVisible = false);
    }
    setState(() {});
  }

  Future<void> _connect() async {
    final host = _ipController.text.trim();
    final controlPort = int.tryParse(_portController.text.trim()) ?? 52017;
    final videoPort = int.tryParse(_videoPortController.text.trim()) ?? 52018;

    _connection.setHost(host);
    _connection.setControlPort(controlPort);
    _connection.setVideoPort(videoPort);

    if (_connection.transportType == TransportType.wifi && host.isEmpty) {
      _showSnackBar('Enter the PC IP address');
      return;
    }

    if (_connection.transportType == TransportType.bluetooth) {
      if (_selectedBtAddress == null) {
        _showSnackBar('Select a paired Bluetooth device first');
        return;
      }
      _connection.setBtDevice(_selectedBtAddress!);
    }

    _connection.setVideoEnabled(_videoEnabled);
    await _connection.connect();
  }

  Future<void> _loadBtDevices() async {
    try {
      final result = await _inputChannel.invokeMethod<List>('getPairedBluetoothDevices');
      if (!mounted) return;
      setState(() {
        _btDevices = (result ?? [])
            .cast<Map>()
            .map((m) => {'name': m['name'] as String, 'address': m['address'] as String})
            .toList();
      });
      if (_btDevices.isEmpty) {
        _showSnackBar('No paired Bluetooth devices found. Pair with your PC first.');
      }
    } catch (e) {
      _showSnackBar('Bluetooth error: $e');
    }
  }

  void _disconnect() {
    _connection.disconnect();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    setState(() {
      _completedStrokes.clear();
      _currentStroke.clear();
    });
  }

  void _toggleSoftKb() {
    setState(() => _softKbVisible = !_softKbVisible);
    if (_softKbVisible) {
      _softKbFocus.requestFocus();
    } else {
      _softKbFocus.unfocus();
    }
  }

  void _sendKey(String char, String label, int logical) {
    _connection.sendKey({'type': 'key', 'action': 'down', 'char': char, 'label': label, 'logical': logical});
    _connection.sendKey({'type': 'key', 'action': 'up',   'char': char, 'label': label, 'logical': logical});
  }

  void _onSoftKbChanged(String value) {
    if (!_connection.isConnected) return;
    if (value.length > _prevSoftKbText.length) {
      final newChars = value.substring(_prevSoftKbText.length);
      for (final ch in newChars.characters) {
        if (ch == '\n') {
          _sendKey('', 'Enter', 0x100000000d);
        } else {
          _sendKey(ch, ch, ch.codeUnitAt(0));
        }
      }
    } else if (value.length < _prevSoftKbText.length) {
      final count = _prevSoftKbText.length - value.length;
      for (var i = 0; i < count; i++) {
        _sendKey('', 'Backspace', 0x100000008);
      }
    }
    _prevSoftKbText = value;
  }

  void _handleKeyEvent(KeyEvent event) {
    if (!_connection.isConnected) return;
    final action = event is KeyUpEvent ? 'up' : 'down';
    _connection.sendKey({
      'type': 'key',
      'action': action,
      'char': event.character ?? '',
      'label': event.logicalKey.keyLabel,
      'logical': event.logicalKey.keyId,
    });
  }

  void _handleScroll(PointerSignalEvent event, Size canvasSize) {
    if (!_connection.isConnected) return;
    if (event is! PointerScrollEvent) return;
    final x = event.localPosition.dx;
    final y = event.localPosition.dy;
    final (normX, normY) = _mapToImageArea(x, y, canvasSize);
    _connection.sendKey({
      'type': 'scroll',
      'x': normX,
      'y': normY,
      'dx': event.scrollDelta.dx,
      'dy': event.scrollDelta.dy,
    });
  }

  void _handlePointerEvent(String action, PointerEvent event, Size canvasSize) {
    if (!_connection.isConnected) return;
    if (_touchLocked && event.kind == PointerDeviceKind.touch) return;

    final tool = switch (event.kind) {
      PointerDeviceKind.stylus => 'stylus',
      PointerDeviceKind.invertedStylus => 'eraser',
      PointerDeviceKind.touch => 'finger',
      _ => 'unknown',
    };

    // Treat hover (pressure==0) as move without click
    final rawPressure = event.pressure;
    final isContact = rawPressure > 0.02;

    // Remap 'down' to 'move' if no actual contact (hover)
    final effectiveAction = (action == 'down' && !isContact) ? 'move' : action;
    final pressure = isContact ? rawPressure : 0.0;

    // Determine button (eraser tip = right-click; mouse secondary/middle)
    final String button;
    if (tool == 'eraser') {
      button = 'secondary';
    } else if ((event.buttons & kSecondaryMouseButton) != 0) {
      button = 'secondary';
    } else if ((event.buttons & kMiddleMouseButton) != 0) {
      button = 'middle';
    } else {
      button = 'primary';
    }

    final x = event.localPosition.dx;
    final y = event.localPosition.dy;

    // Map coordinates to the active image area (accounting for letterbox / fill)
    final (normX, normY) = _mapToImageArea(x, y, canvasSize);

    _connection.send(PenEvent(
      x: normX,
      y: normY,
      pressure: pressure,
      action: effectiveAction,
      tool: tool,
      button: button,
    ));

    setState(() {
      _hoverPos = Offset(x, y);
      if (effectiveAction == 'down') {
        _currentStroke.clear();
        _currentStroke.add(_StrokePoint(x, y, pressure));
      } else if (effectiveAction == 'move' && isContact) {
        _currentStroke.add(_StrokePoint(x, y, pressure));
      } else if (effectiveAction == 'up' || action == 'up') {
        if (_currentStroke.length > 1) {
          _completedStrokes.add(_TimedStroke(List.from(_currentStroke)));
        }
        _currentStroke.clear();
      }
    });
  }

  (double, double) _mapToImageArea(double x, double y, Size canvas) {
    if (canvas.isEmpty) return (0, 0);

    if (_fillScreen) {
      return ((x / canvas.width).clamp(0.0, 1.0),
              (y / canvas.height).clamp(0.0, 1.0));
    }

    // BoxFit.contain — compensate for letterbox bars
    final pcW = _connection.pcScreenWidth.toDouble();
    final pcH = _connection.pcScreenHeight.toDouble();
    final pcAspect = pcW / pcH;
    final canvasAspect = canvas.width / canvas.height;

    double imgW, imgH, xOff, yOff;
    if (pcAspect > canvasAspect) {
      imgW = canvas.width;
      imgH = canvas.width / pcAspect;
      xOff = 0;
      yOff = (canvas.height - imgH) / 2;
    } else {
      imgH = canvas.height;
      imgW = canvas.height * pcAspect;
      xOff = (canvas.width - imgW) / 2;
      yOff = 0;
    }

    return (((x - xOff) / imgW).clamp(0.0, 1.0),
            ((y - yOff) / imgH).clamp(0.0, 1.0));
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _connection.isConnected;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            if (!isConnected)
              _buildConnectionPanel()
            else
              _buildConnectedBar(),
            Expanded(
              child: isConnected ? _buildCanvas() : _buildIdleState(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barBtn({
    required String label,
    required bool active,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? Colors.white24 : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white30, width: 1),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildTransportSelector() {
    const options = [
      (TransportType.wifi,      'WiFi'),
      (TransportType.usb,       'USB'),
      (TransportType.bluetooth, 'Bluetooth'),
    ];
    return Row(
      children: options.map((opt) {
        final (type, label) = opt;
        final selected = _connection.transportType == type;
        return Expanded(
          child: GestureDetector(
            onTap: () {
              _connection.setTransport(type);
              setState(() => _videoEnabled = type != TransportType.bluetooth);
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                  width: 2,
                ),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: selected ? Colors.white : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildConnectionPanel() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '📱 Boox Tablet Driver',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),

            _buildTransportSelector(),
            const SizedBox(height: 16),

            if (_connection.transportType == TransportType.wifi) ...[
              TextField(
                controller: _ipController,
                decoration: const InputDecoration(
                  labelText: 'PC IP Address',
                  hintText: 'e.g. 192.168.0.22',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
            ],

            if (_connection.transportType == TransportType.usb) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('USB via ADB',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amber.shade900)),
                    const SizedBox(height: 8),
                    Text(
                      '1. Connect Boox to PC via USB\n'
                      '2. Enable USB debugging on Boox\n'
                      '3. Tap Connect below',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.amber.shade900,
                          height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (_connection.transportType == TransportType.bluetooth) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Bluetooth — paruj tablet z PC wcześniej.',
                      style: TextStyle(
                          fontSize: 13, color: Colors.blue.shade900, height: 1.5),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _loadBtDevices,
                      icon: const Icon(Icons.bluetooth_searching, size: 18),
                      label: const Text('Wyszukaj sparowane urządzenia'),
                    ),
                    if (_btDevices.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedBtAddress,
                        hint: const Text('Wybierz urządzenie'),
                        items: _btDevices.map((d) {
                          return DropdownMenuItem<String>(
                            value: d['address'],
                            child: Text('${d['name']}  (${d['address']})'),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val == null) return;
                          setState(() {
                            _selectedBtAddress = val;
                            _selectedBtName = _btDevices
                                .firstWhere((d) => d['address'] == val)['name']!;
                          });
                        },
                      ),
                    ],
                    if (_selectedBtAddress != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Wybrano: $_selectedBtName',
                          style: TextStyle(
                              color: Colors.blue.shade800,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Wideo (podgląd ekranu PC)'),
              subtitle: Text(
                _videoEnabled
                    ? 'Strumień wideo włączony'
                    : 'Wyłączone — sterowanie działa, bez podglądu',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              value: _videoEnabled,
              onChanged: (v) => setState(() => _videoEnabled = v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Control port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _videoPortController,
              decoration: const InputDecoration(
                labelText: 'Video port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),

            FilledButton(
              onPressed: _connection.state == ConnState.connecting
                  ? null
                  : _connect,
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16)),
              child: _connection.state == ConnState.connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('🔗 Connect to PC'),
            ),

            if (_connection.state == ConnState.error) ...[
              const SizedBox(height: 8),
              Text(
                _connection.errorMessage,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedBar() {
    final label = switch (_connection.transportType) {
      TransportType.wifi => 'WiFi',
      TransportType.usb => 'USB',
      TransportType.bluetooth => 'BT',
    };

    const shortcuts = [
      ('Esc',    'esc',      'Escape'),
      ('PrtSc',  'printscreen', 'PrintScreen'),
      ('Snip',   'snip',     'Zrzut ekranu (Shift+Win+S)'),
      ('Ctrl+C', 'copy',     'Kopiuj'),
      ('Ctrl+V', 'paste',    'Wklej'),
      ('Tab',    'tab',      'Tab'),
      ('Zadania','taskview', 'Widok zadań (Win+Tab)'),
      ('Alt+Tab','alttab',  'Przełącz okno'),
    ];

    return Container(
      color: const Color(0xFF1B5E20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Row(
        children: [
          // Shortcut buttons
          ...shortcuts.map((s) {
            final (lbl, name, tooltip) = s;
            return Tooltip(
              message: tooltip,
              child: GestureDetector(
                onTap: () => _connection.sendShortcut(name),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(lbl,
                    style: const TextStyle(color: Colors.white, fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(width: 6),
          // Toggles
          _barBtn(label: '◐', active: _invertColors, tooltip: 'Inwersja',
              onTap: () => setState(() => _invertColors = !_invertColors)),
          _barBtn(label: '⊞', active: _fillScreen, tooltip: 'Wypełnij ekran',
              onTap: () => setState(() => _fillScreen = !_fillScreen)),
          _barBtn(label: '🤚', active: _touchLocked, tooltip: _touchLocked ? 'Odblokuj dotyk' : 'Zablokuj dotyk (tylko rysik)',
              onTap: () => setState(() => _touchLocked = !_touchLocked)),
          _barBtn(
            label: '🖥',
            active: _connection.isVideoConnected,
            tooltip: _connection.isVideoConnected ? 'Wyłącz podgląd ekranu' : 'Włącz podgląd ekranu',
            onTap: () {
              if (_connection.isVideoConnected) {
                _connection.disableVideo();
              } else {
                _connection.enableVideo();
              }
            },
          ),
          if (!_physicalKbConnected)
            _barBtn(label: '⌨', active: _softKbVisible, tooltip: 'Klawiatura ekranowa',
                onTap: _toggleSoftKb),
          if (_connection.capsLock)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.shade700,
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Text('⇪', style: TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          const Spacer(),
          // Connection status
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$label${_connection.isVideoConnected ? ' 🖥' : ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              if (_connection.connectedPcName.isNotEmpty)
                Text(
                  _connection.connectedPcName,
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              if (_connection.transportType == TransportType.wifi) ...[
                if (_tabletIp.isNotEmpty)
                  Text(
                    '📱 $_tabletIp',
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                Text(
                  '🖥 ${_connection.host}',
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ],
          ),
          const SizedBox(width: 8),
          // Disconnect
          GestureDetector(
            onTap: _disconnect,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('✕', style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdleState() {
    final modeHint = switch (_connection.transportType) {
      TransportType.wifi => 'Connect over WiFi',
      TransportType.usb => 'Connect via USB (ADB)',
      TransportType.bluetooth => 'Connect over Bluetooth',
    };

    final isReconnecting = _connection.isReconnecting;
    final reconnectStatus = _connection.reconnectStatus;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isReconnecting) ...[
            const SizedBox(
              width: 48, height: 48,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              reconnectStatus,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.orange[700]),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _disconnect,
              child: const Text('Anuluj'),
            ),
          ] else ...[
            Icon(Icons.touch_app, size: 80, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              '$modeHint to start using\nyour Boox as a graphics tablet',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey[500], height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasSize = constraints.biggest;
        return Focus(
          autofocus: true,
          child: Listener(
            onPointerDown: (e) => _handlePointerEvent('down', e, canvasSize),
            onPointerMove: (e) => _handlePointerEvent('move', e, canvasSize),
            onPointerUp: (e) => _handlePointerEvent('up', e, canvasSize),
            onPointerCancel: (e) => _handlePointerEvent('up', e, canvasSize),
            onPointerHover: (e) => _handlePointerEvent('move', e, canvasSize),
            onPointerSignal: (e) => _handleScroll(e, canvasSize),
            child: _maybeInvert(
              Stack(
                children: [
                  if (_connection.latestFrame != null)
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: Image.memory(
                          _connection.latestFrame!,
                          fit: _fillScreen ? BoxFit.fill : BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                          gaplessPlayback: true,
                        ),
                      ),
                    )
                  else
                    Container(color: const Color(0xFFF5F5F5)),

                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: _GridPainter()),
                    ),
                  ),

                  if (_hoverPos != null && _connection.cursorShape != 'arrow')
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _CursorPainter(_hoverPos!, _connection.cursorShape),
                        ),
                      ),
                    ),

                  // Hidden TextField for soft keyboard input
                  Positioned(
                    left: -200, top: -200, width: 1, height: 1,
                    child: TextField(
                      controller: _softKbController,
                      focusNode: _softKbFocus,
                      onChanged: _onSoftKbChanged,
                      onSubmitted: (_) => _sendKey('', 'Enter', 0x100000000d),
                      keyboardType: TextInputType.multiline,
                      maxLines: null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _maybeInvert(Widget child) {
    if (!_invertColors) return child;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        -1,  0,  0, 0, 255,
         0, -1,  0, 0, 255,
         0,  0, -1, 0, 255,
         0,  0,  0, 1,   0,
      ]),
      child: child,
    );
  }
}

class _StrokePoint {
  final double x;
  final double y;
  final double pressure;
  _StrokePoint(this.x, this.y, this.pressure);
}

class _TimedStroke {
  final List<_StrokePoint> points;
  final int _startMs;

  _TimedStroke(this.points) : _startMs = DateTime.now().millisecondsSinceEpoch;

  bool get isDead => DateTime.now().millisecondsSinceEpoch - _startMs > 2000;

  double get opacity {
    final age = DateTime.now().millisecondsSinceEpoch - _startMs;
    if (age < 600) return 0.85;
    if (age > 1800) return 0.0;
    return 0.85 * (1.0 - (age - 600) / 1200.0);
  }
}

class _CursorPainter extends CustomPainter {
  final Offset pos;
  final String shape;
  _CursorPainter(this.pos, this.shape);

  static Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..strokeWidth = w
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  // Draw shape twice: white outline then black stroke for contrast on any bg.
  void _double(Canvas canvas, void Function(Canvas, Paint) draw) {
    draw(canvas, _stroke(Colors.white, 3.5));
    draw(canvas, _stroke(Colors.black, 1.8));
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (shape) {
      case 'ibeam':     _drawIBeam(canvas);    break;
      case 'wait':      _drawWait(canvas);      break;
      case 'crosshair': _drawCrosshair(canvas); break;
      case 'size_ew':   _drawArrowH(canvas);    break;
      case 'size_ns':   _drawArrowV(canvas);    break;
      case 'size_nwse': _drawArrowDiag(canvas, nwse: true);  break;
      case 'size_nesw': _drawArrowDiag(canvas, nwse: false); break;
      case 'size_all':  _drawArrowAll(canvas);  break;
      case 'no':        _drawNo(canvas);        break;
      case 'hand':      _drawHand(canvas);      break;
      default:          _drawArrow(canvas);     break;
    }
  }

  void _drawArrow(Canvas canvas) {
    final path = Path()
      ..moveTo(pos.dx, pos.dy)
      ..lineTo(pos.dx, pos.dy + 20)
      ..lineTo(pos.dx + 5, pos.dy + 14)
      ..lineTo(pos.dx + 11, pos.dy + 22)
      ..lineTo(pos.dx + 14, pos.dy + 21)
      ..lineTo(pos.dx + 8, pos.dy + 13)
      ..lineTo(pos.dx + 15, pos.dy + 13)
      ..close();
    canvas.drawPath(path, _stroke(Colors.white, 3.5));
    canvas.drawPath(path, _stroke(Colors.black, 1.8));
  }

  void _drawIBeam(Canvas canvas) {
    const h = 20.0; const w = 8.0;
    _double(canvas, (c, p) {
      c.drawLine(Offset(pos.dx, pos.dy - h / 2), Offset(pos.dx, pos.dy + h / 2), p);
      c.drawLine(Offset(pos.dx - w / 2, pos.dy - h / 2), Offset(pos.dx + w / 2, pos.dy - h / 2), p);
      c.drawLine(Offset(pos.dx - w / 2, pos.dy + h / 2), Offset(pos.dx + w / 2, pos.dy + h / 2), p);
    });
  }

  void _drawWait(Canvas canvas) {
    final path = Path()
      ..moveTo(pos.dx - 10, pos.dy - 14)
      ..lineTo(pos.dx + 10, pos.dy - 14)
      ..lineTo(pos.dx, pos.dy)
      ..lineTo(pos.dx + 10, pos.dy + 14)
      ..lineTo(pos.dx - 10, pos.dy + 14)
      ..lineTo(pos.dx, pos.dy)
      ..close();
    canvas.drawPath(path, _stroke(Colors.white, 3.5));
    canvas.drawPath(path, _stroke(Colors.black, 1.8));
  }

  void _drawCrosshair(Canvas canvas) {
    const arm = 18.0; const gap = 4.0;
    _double(canvas, (c, p) {
      c.drawLine(Offset(pos.dx - arm, pos.dy), Offset(pos.dx - gap, pos.dy), p);
      c.drawLine(Offset(pos.dx + gap, pos.dy), Offset(pos.dx + arm, pos.dy), p);
      c.drawLine(Offset(pos.dx, pos.dy - arm), Offset(pos.dx, pos.dy - gap), p);
      c.drawLine(Offset(pos.dx, pos.dy + gap), Offset(pos.dx, pos.dy + arm), p);
      c.drawCircle(pos, gap, p);
    });
  }

  void _drawDoubleArrow(Canvas canvas, Offset dir) {
    final perp = Offset(-dir.dy, dir.dx);
    const shaft = 16.0; const head = 7.0;

    final path = Path();
    path.moveTo(pos.dx - dir.dx * shaft, pos.dy - dir.dy * shaft);
    path.lineTo(pos.dx - dir.dx * (shaft - head) + perp.dx * head * 0.5,
                pos.dy - dir.dy * (shaft - head) + perp.dy * head * 0.5);
    path.lineTo(pos.dx - dir.dx * (shaft - head) - perp.dx * head * 0.5,
                pos.dy - dir.dy * (shaft - head) - perp.dy * head * 0.5);
    path.close();
    path.moveTo(pos.dx + dir.dx * shaft, pos.dy + dir.dy * shaft);
    path.lineTo(pos.dx + dir.dx * (shaft - head) + perp.dx * head * 0.5,
                pos.dy + dir.dy * (shaft - head) + perp.dy * head * 0.5);
    path.lineTo(pos.dx + dir.dx * (shaft - head) - perp.dx * head * 0.5,
                pos.dy + dir.dy * (shaft - head) - perp.dy * head * 0.5);
    path.close();
    canvas.drawPath(path, _stroke(Colors.white, 3.5));
    canvas.drawPath(path, _stroke(Colors.black, 1.8));

    _double(canvas, (c, p) {
      c.drawLine(Offset(pos.dx - dir.dx * shaft, pos.dy - dir.dy * shaft),
                 Offset(pos.dx + dir.dx * shaft, pos.dy + dir.dy * shaft), p);
    });
  }

  void _drawArrowH(Canvas canvas) => _drawDoubleArrow(canvas, const Offset(1, 0));
  void _drawArrowV(Canvas canvas) => _drawDoubleArrow(canvas, const Offset(0, 1));

  void _drawArrowDiag(Canvas canvas, {required bool nwse}) {
    const s = 0.7071; // 1/sqrt(2)
    _drawDoubleArrow(canvas, nwse ? const Offset(s, s) : const Offset(s, -s));
  }

  void _drawArrowAll(Canvas canvas) {
    for (final dir in [
      const Offset(1, 0), const Offset(0, 1),
    ]) {
      _drawDoubleArrow(canvas, dir);
    }
  }

  void _drawNo(Canvas canvas) {
    const r = 13.0;
    _double(canvas, (c, p) {
      c.drawCircle(pos, r, p);
      final s = r * 0.707;
      c.drawLine(Offset(pos.dx - s, pos.dy - s), Offset(pos.dx + s, pos.dy + s), p);
    });
  }

  void _drawHand(Canvas canvas) {
    final path = Path()
      ..moveTo(pos.dx - 2, pos.dy)
      ..lineTo(pos.dx - 2, pos.dy - 18)
      ..lineTo(pos.dx + 2, pos.dy - 18)
      ..lineTo(pos.dx + 2, pos.dy + 2)
      ..lineTo(pos.dx + 9, pos.dy + 2)
      ..lineTo(pos.dx + 9, pos.dy + 10)
      ..lineTo(pos.dx - 9, pos.dy + 10)
      ..lineTo(pos.dx - 9, pos.dy)
      ..close();
    canvas.drawPath(path, _stroke(Colors.white, 3.5));
    canvas.drawPath(path, _stroke(Colors.black, 1.8));
  }

  @override
  bool shouldRepaint(covariant _CursorPainter old) =>
      old.pos != pos || old.shape != shape;
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x08000000)
      ..strokeWidth = 0.5;
    const gridSize = 40.0;
    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _StrokePainter extends CustomPainter {
  final List<_TimedStroke> completedStrokes;
  final List<_StrokePoint> currentStroke;

  _StrokePainter({required this.completedStrokes, required this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in completedStrokes) {
      _drawStroke(canvas, stroke.points, stroke.opacity);
    }
    if (currentStroke.length > 1) {
      _drawStroke(canvas, currentStroke, 0.9);
    }
  }

  void _drawStroke(Canvas canvas, List<_StrokePoint> points, double opacity) {
    if (points.length < 2) return;
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final pressure = (p0.pressure + p1.pressure) / 2;
      final paint = Paint()
        ..color = Colors.blue.withValues(alpha: opacity * 0.85)
        ..strokeWidth = 1.0 + pressure * 6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}
