import 'dart:io';

import 'package:karmashala_host/host_paths.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../../core/probe/probe_mode.dart';
import '../../settings/application/settings_controller.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

/// The session host on this machine, or null where there cannot be one. One per
/// app run: the reading is memoised on it, and a second instance would measure
/// — and possibly start — a second time.
final localHostSessionAccessProvider = Provider<LocalHostSessionAccess?>((ref) {
  // A companion build has no filesystem to find a binary in and no business
  // starting a daemon.
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    return null;
  }
  final probe = ref.watch(probeModeProvider);
  if (!probe.enabled) return LocalHostSessionAccess();
  // A probe's host is its own: the owner's is per user, so sharing it would
  // show a probe the owner's sessions and let it end them (§23). No data
  // folder means no scoped host — never a fall back to the real one.
  final paths = probeHostPaths(probe);
  if (paths == null) return null;
  return LocalHostSessionAccess(
    paths: paths,
    serveEnvironment: {kHostDirectoryEnvironmentVariable: paths.directory.path},
  );
});

/// Where a probe's session host lives: `<data folder>/host`, with the socket,
/// lock, log, sessions and store all inside it. A socket path too long to bind
/// falls back to one hashed from this path, as the `ipc/` socket does, so it
/// never lands on the owner's. Null when the probe has no data folder.
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
}

final localHostStatusProvider =
    NotifierProvider<LocalHostStatusController, HostDeployment?>(
      LocalHostStatusController.new,
    );
