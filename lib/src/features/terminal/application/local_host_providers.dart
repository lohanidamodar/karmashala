import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../../ssh/domain/host_deployment.dart';
import '../data/local_host_access.dart';

/// The session host on this machine, or null where there cannot be one.
///
/// One per app run, for the same reason the SSH registry is one per host: the
/// reading is memoised on it, and a second instance would measure — and
/// possibly start — a second time.
final localHostSessionAccessProvider = Provider<LocalHostSessionAccess?>((ref) {
  // A companion build has no filesystem to find a binary in and no business
  // starting a daemon.
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return null;
  return LocalHostSessionAccess();
});

/// Whether a local pane's process belongs to the session host rather than to
/// this app.
///
/// A provider of its own rather than an inline settings read, the same seam
/// `shellIntegrationEnabledProvider` is: a test that only wants a terminal must
/// not have to stand up a settings store to get one.
final hostBackedLocalPanesProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider).hostBackedLocalPanes,
);

/// What Settings shows about the host on this machine.
///
/// Null until something has looked, and it stays null rather than becoming a
/// confident "not running" — §19's first rule. [refresh] runs when the panel
/// opens and when the user asks; nothing polls, and nothing here starts a
/// daemon: [LocalHostSessionAccess.observe] asks and takes no action, so
/// reading Settings with the setting off cannot launch anything.
class LocalHostStatusController extends Notifier<HostDeployment?> {
  @override
  HostDeployment? build() => ref.watch(localHostSessionAccessProvider)?.lastReading;

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
