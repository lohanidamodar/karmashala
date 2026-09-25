import 'dart:io';

import 'package:karmashala_host/host_paths.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../../core/paths/app_support_directory.dart';
import '../../../core/probe/probe_mode.dart';
import '../../settings/application/settings_controller.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

/// Whether this process may reach a session host on this machine at all. Not
/// under `flutter test` (the runner sets `FLUTTER_TEST`): a test's pane would
/// open sessions on the owner's host, or end them. A test about the host
/// itself overrides this, or [localHostSessionAccessProvider].
final localHostReachableProvider = Provider<bool>(
  (ref) => Platform.environment['FLUTTER_TEST'] != 'true',
);

/// The session host on this machine, or null where there cannot be one. One per
/// app run: the reading is memoised on it, and a second instance would measure
/// — and possibly start — a second time.
final localHostSessionAccessProvider = Provider<LocalHostSessionAccess?>((ref) {
  // A companion build has no filesystem to find a binary in and no business
  // starting a daemon.
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    return null;
  }
  if (!ref.watch(localHostReachableProvider)) return null;
  final probe = ref.watch(probeModeProvider);
  // The daemon opens this app's own database, in the folder the app keeps it.
  if (!probe.enabled) {
    return LocalHostSessionAccess(
      dataDirectory: () async => p.absolute((await appSupportDirectory()).path),
    );
  }
  // A probe's host is its own: the owner's is per user, so sharing it would
  // show a probe the owner's sessions and let it end them (§23). No data
  // folder means no scoped host — never a fall back to the real one.
  final paths = probeHostPaths(probe);
  if (paths == null) return null;
  final data = p.absolute(probe.dataDirectory!);
  return LocalHostSessionAccess(
    paths: paths,
    serveEnvironment: {kHostDirectoryEnvironmentVariable: paths.directory.path},
    dataDirectory: () async => data,
    serveFlags: const ['--mcp-port=0', '--companion-port=0'],
  );
});

/// Where a probe's session host lives: `<data folder>/host`, with the socket,
/// lock, log and sessions inside it; its store is the probe's own database. A
/// socket path too long to bind falls back to one hashed from this path, as the
/// `ipc/` socket does, so it never lands on the owner's. Null when the probe
/// has no data folder.
HostPaths? probeHostPaths(ProbeMode probe) {
  final data = probe.dataDirectory;
  if (!probe.enabled || data == null) return null;
  return HostPaths(Directory(p.join(p.absolute(data), 'host')));
}

/// Whether a local pane's process belongs to the session host rather than this
/// app. Its own provider so a terminal test need not stand up a settings store.
final hostBackedLocalPanesProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider).hostBackedLocalPanes,
);

/// What Settings shows about the host on this machine. Null until something has
/// looked, and it stays null rather than becoming a confident "not running".
/// Nothing polls and nothing here starts a daemon — [observe] takes no action.
class LocalHostStatusController extends Notifier<HostDeployment?> {
  @override
  HostDeployment? build() =>
      ref.watch(localHostSessionAccessProvider)?.lastReading;

  bool _busy = false;
  bool get isChecking => _busy;

  Future<void> refresh() async {
    final access = ref.read(localHostSessionAccessProvider);
    if (access == null || _busy) return;
    _busy = true;
    try {
      state = await access.observe();
    } finally {
      _busy = false;
    }
  }

  /// Starts this app's host when none is running — the one reading that
  /// launches a daemon, and only because the person pressed Start.
  Future<void> start() async {
    final access = ref.read(localHostSessionAccessProvider);
    if (access == null || _busy) return;
    _busy = true;
    try {
      access.forget();
      state = await access.deployment();
    } finally {
      _busy = false;
    }
  }

  /// Replaces the running host with this app's. [force] ends the sessions it
  /// holds, so the caller asks the person first.
  Future<void> restart({required bool force}) async {
    final access = ref.read(localHostSessionAccessProvider);
    if (access == null || _busy) return;
    _busy = true;
    try {
      state = await access.restartHost(force: force);
    } finally {
      _busy = false;
    }
  }
}

final localHostStatusProvider =
    NotifierProvider<LocalHostStatusController, HostDeployment?>(
      LocalHostStatusController.new,
    );
