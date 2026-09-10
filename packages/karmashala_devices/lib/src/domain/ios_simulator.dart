/// What a simulator is doing, as `simctl` reports it. Not
/// [DeviceConnectionState]: that decodes adb's words, and a simulator has no
/// notion of a device attached but refusing to talk.
enum SimulatorState {
  /// Running and ready to be talked to.
  booted,

  /// On its way up. `simctl` reports this while services are still starting,
  /// and a command sent now may be refused.
  booting,

  /// On its way down.
  shuttingDown,

  /// Not running.
  shutdown,

  /// A state this build does not know. Kept rather than dropped: a simulator
  /// that exists is worth listing even when what it is doing is unfamiliar.
  unknown;

  /// The literal `simctl` writes in `list devices -j`.
  static SimulatorState parse(String raw) => switch (raw.toLowerCase()) {
    'booted' => booted,
    'booting' => booting,
    'shutting down' || 'shuttingdown' => shuttingDown,
    'shutdown' || 'creating' => shutdown,
    _ => unknown,
  };

  /// Whether commands can be sent right now.
  bool get isReady => this == booted;
}

/// One iOS Simulator, as listed by `xcrun simctl list devices`.
class IosSimulator {
  const IosSimulator({
    required this.udid,
    required this.name,
    required this.state,
    required this.runtime,
    required this.deviceTypeIdentifier,
    required this.isAvailable,
    this.dataPathSize,
  });

  /// The simulator's UDID — its identity everywhere `simctl` is concerned, and
  /// what this app names it by.
  final String udid;

  /// What its owner called it: "iPhone 17 Pro".
  final String name;

  final SimulatorState state;

  /// The runtime identifier, e.g.
  /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.
  final String runtime;

  /// The device type, e.g.
  /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`.
  final String deviceTypeIdentifier;

  /// Whether its runtime is installed. An unavailable simulator is still a row
  /// in the device set, but offering it as bootable ends in a spinner.
  final bool isAvailable;

  /// Bytes its data container occupies, when `simctl` reported one.
  final int? dataPathSize;

  /// "iOS 26.4" from the runtime identifier, or the identifier itself when it
  /// is not shaped the way this build expects.
  String get runtimeName {
    const prefix = 'com.apple.CoreSimulator.SimRuntime.';
    if (!runtime.startsWith(prefix)) return runtime;
    final rest = runtime.substring(prefix.length);
    final dash = rest.indexOf('-');
    if (dash < 0) return rest;
    final platform = rest.substring(0, dash);
    final version = rest.substring(dash + 1).replaceAll('-', '.');
    return '$platform $version';
  }

  /// What to show in a list: two simulators of the same model on different
  /// runtimes are different machines, and the name alone does not say so.
  String get displayName => '$name · $runtimeName';

  @override
  String toString() => 'IosSimulator($udid $name ${state.name})';
}
