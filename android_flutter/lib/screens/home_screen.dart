import 'dart:ui';

import 'package:flutter/material.dart';

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
  final List<List<_StrokePoint>> _completedStrokes = [];

  @override
  void initState() {
    super.initState();
    _connection.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _connection.removeListener(_onStateChanged);
    _connection.dispose();
    _ipController.dispose();
    _portController.dispose();
    _videoPortController.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
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

    await _connection.connect();
  }

  void _disconnect() {
    _connection.disconnect();
    setState(() {
      _completedStrokes.clear();
      _currentStroke.clear();
    });
  }

  void _handlePointerEvent(String action, PointerEvent event) {
    if (!_connection.isConnected) return;

    final tool = switch (event.kind) {
      PointerDeviceKind.stylus => 'stylus',
      PointerDeviceKind.invertedStylus => 'eraser',
      PointerDeviceKind.touch => 'finger',
      _ => 'unknown',
    };

    final pressure = event.pressure > 0 ? event.pressure : 0.5;
    final x = event.localPosition.dx;
    final y = event.localPosition.dy;

    _connection.send(PenEvent(
      x: x,
      y: y,
      pressure: pressure,
      action: action,
      tool: tool,
    ));

    setState(() {
      if (action == 'down') {
        _currentStroke.clear();
        _currentStroke.add(_StrokePoint(x, y, pressure));
      } else if (action == 'move') {
        _currentStroke.add(_StrokePoint(x, y, pressure));
      } else if (action == 'up') {
        if (_currentStroke.length > 1) {
          _completedStrokes.add(List.from(_currentStroke));
        }
        _currentStroke.clear();
      }
    });
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
            Row(
              children: [
                Icon(Icons.tablet_mac,
                    size: 28, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  'Boox Tablet Driver',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 20),

            SegmentedButton<TransportType>(
              segments: const [
                ButtonSegment(
                  value: TransportType.wifi,
                  label: Text('WiFi'),
                  icon: Icon(Icons.wifi),
                ),
                ButtonSegment(
                  value: TransportType.usb,
                  label: Text('USB'),
                  icon: Icon(Icons.usb),
                ),
                ButtonSegment(
                  value: TransportType.bluetooth,
                  label: Text('BT'),
                  icon: Icon(Icons.bluetooth),
                ),
              ],
              selected: {_connection.transportType},
              onSelectionChanged: (sel) =>
                  _connection.setTransport(sel.first),
            ),
            const SizedBox(height: 16),

            if (_connection.transportType == TransportType.wifi) ...[
              TextField(
                controller: _ipController,
                decoration: const InputDecoration(
                  labelText: 'PC IP Address',
                  hintText: 'e.g. 192.168.0.22',
                  prefixIcon: Icon(Icons.computer),
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
                child: Text(
                  'Bluetooth requires a paired device.\n'
                  'Pair your Boox with the Windows PC first.',
                  style: TextStyle(
                      fontSize: 13, color: Colors.blue.shade900, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
            ],

            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Control port',
                prefixIcon: Icon(Icons.settings_ethernet),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _videoPortController,
              decoration: const InputDecoration(
                labelText: 'Video port',
                prefixIcon: Icon(Icons.monitor),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: _connection.state == ConnState.connecting
                  ? null
                  : _connect,
              icon: _connection.state == ConnState.connecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.link),
              label: Text(
                _connection.state == ConnState.connecting
                    ? 'Connecting...'
                    : 'Connect to PC',
              ),
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16)),
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
    final transportLabels = {
      TransportType.wifi: 'WiFi',
      TransportType.usb: 'USB',
      TransportType.bluetooth: 'BT',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0xFF1B5E20),
      child: Row(
        children: [
          const SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.greenAccent),
          ),
          const SizedBox(width: 8),
          Text(
            'Connected (${transportLabels[_connection.transportType]})',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600),
          ),
          if (_connection.isVideoConnected) ...[
            const SizedBox(width: 4),
            const Icon(Icons.monitor, size: 14, color: Colors.white70),
          ],
          const Spacer(),
          Text(
            '${_connection.host}:${_connection.controlPort}',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 24,
            child: TextButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off, size: 16),
              label: const Text('Disconnect', style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
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

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            '$modeHint to start using\nyour Boox as a graphics tablet',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey[500], height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    return Listener(
      onPointerDown: (e) => _handlePointerEvent('down', e),
      onPointerMove: (e) => _handlePointerEvent('move', e),
      onPointerUp: (e) => _handlePointerEvent('up', e),
      onPointerCancel: (e) => _handlePointerEvent('up', e),
      child: Stack(
        children: [
          if (_connection.latestFrame != null)
            Positioned.fill(
              child: RepaintBoundary(
                child: Image.memory(
                  _connection.latestFrame!,
                  fit: BoxFit.contain,
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

          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _StrokePainter(
                  completedStrokes: _completedStrokes,
                  currentStroke: _currentStroke,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StrokePoint {
  final double x;
  final double y;
  final double pressure;
  _StrokePoint(this.x, this.y, this.pressure);
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
  final List<List<_StrokePoint>> completedStrokes;
  final List<_StrokePoint> currentStroke;

  _StrokePainter({required this.completedStrokes, required this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in completedStrokes) {
      _drawStroke(canvas, stroke, 0.7);
    }
    if (currentStroke.length > 1) {
      _drawStroke(canvas, currentStroke, 1.0);
    }
  }

  void _drawStroke(Canvas canvas, List<_StrokePoint> points, double opacity) {
    if (points.length < 2) return;
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final pressure = (p0.pressure + p1.pressure) / 2;
      final paint = Paint()
        ..color = Colors.blue.withValues(alpha: opacity * 0.8)
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
