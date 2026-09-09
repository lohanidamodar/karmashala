import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/process_handle.dart';
import '../../devices/application/device_providers.dart';
import '../../devices/data/adb_service.dart';
import '../domain/vm_service_log_line.dart';
import 'attached_apps.dart';

/// How many distinct announcements one device's log may produce.
///
/// `logcat` replays its ring buffer when a stream opens, which is what finds an
/// app that started before the pane did — and also every run that has since
/// ended. The bound is on `adb forward` calls, not on time: past this many the
/// device is not asked for another tunnel.
const int kMaxDeviceAnnouncements = 16;

/// The tags the Dart VM's announcement can arrive under. `flutter` is the one
/// measured on this machine; `DartVM` is in `flutter attach`'s own allowlist.
const List<String> kVmServiceLogTags = <String>['flutter', 'DartVM'];

/// **Finds a Flutter app running on a phone or emulator, from the log.**
///
/// The Dart VM prints `The Dart VM service is listening on http://…` to stdout
/// and Android routes it to `logcat`; the port in it is a port on the device,
/// so an `adb forward` makes it reachable here. That is exactly what `flutter
/// attach` does, and it is the only way in for an app nothing on this machine
/// started — one launched by tapping its icon, or by another tool.
///
/// **Nothing polls.** A line is an event. The stream is filtered at adb to the
/// two tags that can carry the announcement, so a busy device costs nothing to
/// watch, and it is dropped the moment nothing is watching.
class AndroidAppDiscovery {
  AndroidAppDiscovery({
    required AdbService? adb,
    required AttachedApps apps,
    AppLogger? logger,
    // Public parameter names over private fields, as `DeviceLogcatSession`
    // does: `_adb:` would be a poor argument to write at a call site.
    // ignore: prefer_initializing_formals
  }) : _adb = adb,
       // ignore: prefer_initializing_formals
       _apps = apps,
       _logger = logger ?? AppLogger.named('flutter_apps');

  final AdbService? _adb;
  final AttachedApps _apps;
  final AppLogger _logger;

  final Map<String, ProcessHandle> _streams = <String, ProcessHandle>{};
  final Map<String, StreamSubscription<String>> _lines =
      <String, StreamSubscription<String>>{};

  /// One entry per announcement already acted on, so an address repeated in
  /// the log — a replayed buffer, a line printed twice — is offered once.
  final Set<String> _announced = <String>{};

  /// How many `adb forward` calls this has made. Counted rather than timed:
  /// the contract is one tunnel per app, whatever the log does.
  int forwardsMade = 0;

  var _disposed = false;

  Iterable<String> get watching => _streams.keys;

  /// Reads the log of each serial in [serials], and stops reading any device
  /// no longer in it.
  Future<void> watch(Iterable<String> serials) async {
    if (_disposed) return;
    final wanted = serials.toSet();
    for (final serial in _streams.keys.toList()) {
      if (!wanted.contains(serial)) _stop(serial);
    }
    for (final serial in wanted) {
      if (_streams.containsKey(serial)) continue;
      await _start(serial);
      if (_disposed) return;
    }
  }

  Future<void> _start(String serial) async {
    final adb = _adb;
    if (adb == null) return;
    final ProcessHandle process;
    try {
      process = await adb.streamLogcat(serial, tags: kVmServiceLogTags);
    } on Object catch (error) {
      _logger.debug('reading $serial log failed: $error');
      return;
    }
    if (_disposed) {
      await process.kill();
      return;
    }
    _streams[serial] = process;
    _lines[serial] = process.stdoutLines.listen(
      (line) => unawaited(_onLine(serial, line)),
      onError: (Object error) => _logger.debug('$serial log: $error'),
      onDone: () => _stop(serial),
      cancelOnError: false,
    );
  }

  Future<void> _onLine(String serial, String line) async {
    final deviceUri = vmServiceUriInDeviceLogLine(line);
    if (deviceUri == null) return;
    final key = '$serial ${deviceUri.port}${deviceUri.path}';
    if (_announced.contains(key)) return;
    if (_announced.length >= kMaxDeviceAnnouncements) return;
    _announced.add(key);

    final adb = _adb;
    if (adb == null) return;
    final int? hostPort;
    try {
      hostPort = await adb.forwardToFreePort(serial, deviceUri.port);
      forwardsMade++;
    } on Object catch (error) {
      _logger.debug('forwarding $serial:${deviceUri.port} failed: $error');
      return;
    }
    if (hostPort == null || _disposed) return;
    await _apps.offerFromDevice(
      hostUri: vmServiceUriOnHost(deviceUri, hostPort),
      serial: serial,
    );
  }

  void _stop(String serial) {
    unawaited(_lines.remove(serial)?.cancel());
    unawaited(_streams.remove(serial)?.kill());
  }

  /// Drops every stream. The `adb forward` tunnels are deliberately left in
  /// place: an app found here is attached *through* one, and removing it would
  /// cut a live connection to close a socket adb reclaims when the device goes.
  void dispose() {
    _disposed = true;
    for (final serial in _streams.keys.toList()) {
      _stop(serial);
    }
  }
}

/// Reads every connected Android device's log while something is watching.
///
/// `autoDispose` is the whole bound on cost, the same way
/// `deviceLogcatSessionProvider` is bounded: a closed pane holds no `logcat`
/// process, because nothing is left subscribed to this.
final androidAppDiscoveryProvider =
    FutureProvider.autoDispose<AndroidAppDiscovery>((ref) async {
      final discovery = AndroidAppDiscovery(
        adb: ref.watch(adbServiceProvider),
        apps: ref.read(attachedAppsProvider.notifier),
      );
      ref.onDispose(discovery.dispose);
      final devices = await ref.watch(devicesProvider.future);
      await discovery.watch(devices.map((device) => device.serial));
      return discovery;
    });
