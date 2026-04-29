class PenEvent {
  final double x;
  final double y;
  final double pressure;
  final String action; // 'down', 'move', 'up'
  final String tool; // 'stylus', 'finger', 'eraser', 'unknown'
  final String button; // 'primary', 'secondary', 'middle'

  PenEvent({
    required this.x,
    required this.y,
    required this.pressure,
    required this.action,
    required this.tool,
    this.button = 'primary',
  });

  Map<String, dynamic> toJson() => {
        'type': 'pen',
        'x': x,
        'y': y,
        'pressure': pressure,
        'action': action,
        'tool': tool,
        'button': button,
      };
}
