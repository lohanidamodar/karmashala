/// One agent's hold on one device, as the server's claims registry tells it
/// (slice 4a) — so a client's pane on the server's machine can say who is
/// driving a device and ask before a person acts on it. The same fields as
/// `karmashala_devices`' `DeviceClaim`, which this package does not import.
final class DeviceHold {
  const DeviceHold({
    required this.deviceId,
    required this.holderSessionId,
    required this.takenAt,
    required this.lastCallAt,
    required this.lastVerb,
    required this.calls,
    this.holderTitle,
  });

  /// The device as its driver names it — `emulator-5554`, or a simulator udid.
  final String deviceId;
  final String holderSessionId;

  /// What the holder session is called, or null when the server has only its
  /// id.
  final String? holderTitle;
  final DateTime takenAt;
  final DateTime lastCallAt;
  final String lastVerb;
  final int calls;

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'holderSessionId': holderSessionId,
    'holderTitle': ?holderTitle,
    'takenAt': takenAt.toUtc().toIso8601String(),
    'lastCallAt': lastCallAt.toUtc().toIso8601String(),
    'lastVerb': lastVerb,
    'calls': calls,
  };

  static DeviceHold fromJson(Map<String, Object?> json) => DeviceHold(
    deviceId: json['deviceId']! as String,
    holderSessionId: json['holderSessionId']! as String,
    holderTitle: json['holderTitle'] as String?,
    takenAt: DateTime.parse(json['takenAt']! as String),
    lastCallAt: DateTime.parse(json['lastCallAt']! as String),
    lastVerb: json['lastVerb'] as String? ?? '',
    calls: json['calls'] as int? ?? 0,
  );
}
