import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

/// Hands the attached-apps registry an app a device announced, at the address
/// `adb forward` made for it on the server's machine.
typedef DeviceAppOffer =
    Future<void> Function({required Uri hostUri, required String serial});

/// How many distinct announcements one device's log may produce — `logcat`
/// replays its ring buffer, so the bound is on `adb forward` calls, not time.
const int kMaxDeviceAnnouncements = 16;

/// The tags the Dart VM's announcement can arrive under. `flutter` is the one
/// measured on this machine; `DartVM` is in `flutter attach`'s own allowlist.
const List<String> kVmServiceLogTags = <String>['flutter', 'DartVM'];

/// Finds a Flutter app on a phone attached to **the server's machine** from
/// its log line and `adb forward`s the port — the only way in for an app
/// nothing here started (slice 4a; the app did this on its own machine until
/// then, which a server elsewhere could not reach).
///
/// Costs a `logcat` per device, so it runs only while Flutter apps are being
/// looked at: [looked] (a client's `flutter.apps {look}`, the `flutter_apps`
/// tool) keeps it on for [lookingFor], re-reading which devices are attached
/// every [rescanEvery]; after that every reader is stopped.
class DeviceAppDiscovery {
  DeviceAppDiscovery({
    required Future<AdbService?> Function() adb,
    required DeviceAppOffer offer,
    this.lookingFor = const Duration(minutes: 10),
    this.rescanEvery = const Duration(seconds: 10),
    this.clock = const SystemClock(),
    void Function(String message)? log,
  }) : _adb = adb,
       _offer = offer,
       _log = log ?? _silent;

  final Future<AdbService?> Function() _adb;
  final DeviceAppOffer _offer;
  final Duration lookingFor;
  final Duration rescanEvery;
  final Clock clock;
  final void Function(String message) _log;

  static void _silent(String _) {}

  final Map<String, ProcessHandle> _streams = <String, ProcessHandle>{};
  final Map<String, StreamSubscription<String>> _lines =
      <String, StreamSubscription<String>>{};

  /// One entry per announcement already acted on, so an address repeated in
  /// the log — a replayed buffer, a line printed twice — is offered once.
  final Set<String> _announced = <String>{};

  /// How many `adb forward` calls this has made. Counted rather than timed:
  /// the contract is one tunnel per app, whatever the log does.
  int forwardsMade = 0;

  DateTime? _until;
  Timer? _rescan;
  Future<void>? _scanning;
  var _closed = false;

  /// The devices whose log is being read.
  Iterable<String> get watching => _streams.keys;

  /// Whether it is on.
  bool get active => _rescan != null;

  /// Somebody looked at the Flutter apps: read every attached device's log
  /// for [lookingFor] from now. Resolves once the devices were read.
  Future<void> looked() {
    if (_closed) return Future<void>.value();
    _until = clock.nowUtc().add(lookingFor);
    _rescan ??= Timer.periodic(rescanEvery, (_) => unawaited(_tick()));
    return _tick();
  }

  Future<void> _tick() =>
      _scanning ??= _scan().whenComplete(() => _scanning = null);

  Future<void> _scan() async {
    final until = _until;
    if (_closed || until == null || !clock.nowUtc().isBefore(until)) {
      _stopAll();
      return;
    }
    final adb = await _adb();
    if (adb == null) return;
    final List<AndroidDevice> devices;
    try {
      devices = await adb.listDevices();
    } on Object catch (error) {
      _log('the devices could not be listed for Flutter apps ($error)');
      return;
    }
    await watch(adb, [
      for (final device in devices)
        if (device.isReady) device.serial,
    ]);
  }

  /// Reads the log of each serial in [serials], and stops reading any device
  /// no longer in it.
  Future<void> watch(AdbService adb, Iterable<String> serials) async {
    if (_closed) return;
    final wanted = serials.toSet();
    for (final serial in _streams.keys.toList()) {
      if (!wanted.contains(serial)) _stop(serial);
    }
    for (final serial in wanted) {
      if (_streams.containsKey(serial)) continue;
      await _start(adb, serial);
      if (_closed) return;
    }
  }

  Future<void> _start(AdbService adb, String serial) async {
    final ProcessHandle process;
    try {
      process = await adb.streamLogcat(serial, tags: kVmServiceLogTags);
    } on Object catch (error) {
      _log('reading $serial log failed: $error');
      return;
    }
    if (_closed) {
      await process.kill();
      return;
    }
    _streams[serial] = process;
    _lines[serial] = process.stdoutLines.listen(
      (line) => unawaited(_onLine(adb, serial, line)),
      onError: (Object error) => _log('$serial log: $error'),
      onDone: () => _stop(serial),
      cancelOnError: false,
    );
  }

  Future<void> _onLine(AdbService adb, String serial, String line) async {
    final deviceUri = vmServiceUriInDeviceLogLine(line);
    if (deviceUri == null) return;
    final key = '$serial ${deviceUri.port}${deviceUri.path}';
    if (_announced.contains(key)) return;
    if (_announced.length >= kMaxDeviceAnnouncements) return;
    _announced.add(key);

    final int? hostPort;
    try {
      hostPort = await adb.forwardToFreePort(serial, deviceUri.port);
      forwardsMade++;
    } on Object catch (error) {
      _log('forwarding $serial:${deviceUri.port} failed: $error');
      return;
    }
    if (hostPort == null || _closed) return;
    await _offer(
      hostUri: vmServiceUriOnHost(deviceUri, hostPort),
      serial: serial,
    );
  }

  void _stop(String serial) {
    unawaited(_lines.remove(serial)?.cancel());
    unawaited(_streams.remove(serial)?.kill());
  }

  void _stopAll() {
    _rescan?.cancel();
    _rescan = null;
    _until = null;
    for (final serial in _streams.keys.toList()) {
      _stop(serial);
    }
  }

  /// Drops every stream. The `adb forward` tunnels are left in place: an app
  /// found here is attached *through* one, and removing it would cut it.
  void close() {
    _closed = true;
    _stopAll();
  }
}
