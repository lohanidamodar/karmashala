import 'dart:async';
import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show WorktreeCleanupKeys;
import 'package:karmashala_git/cleanup.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../data/git_data.dart';

/// Worktree cleanup's setting: a preference this app writes, which the server
/// sweeps by — on its own schedule, with no app open. Read again whenever any
/// client changes it.
final worktreeCleanupSettingsProvider = Provider<WorktreeCleanupSettings>((
  ref,
) {
  final preferences = ref.watch(appPreferencesProvider);
  final listening = preferences.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(listening.cancel);
  final raw = preferences.read(WorktreeCleanupKeys.settings);
  if (raw == null) return const WorktreeCleanupSettings();
  try {
    return WorktreeCleanupSettings.fromJson(jsonDecode(raw));
  } on FormatException {
    return const WorktreeCleanupSettings();
  }
});

/// What the server's cleanup removed, newest first, and its last sweep —
/// asked once, and told again after every sweep.
final worktreeCleanupLogProvider = FutureProvider<WorktreeCleanupLog>((
  ref,
) async {
  final git = ref.watch(gitDataProvider);
  final listening = git.cleanups.listen((_) => ref.invalidateSelf());
  ref.onDispose(listening.cancel);
  return git.cleanupLog();
});

/// Saves the setting and asks the server for a preview or a sweep.
class WorktreeCleanupController {
  WorktreeCleanupController(this._ref);

  final Ref _ref;

  void save(WorktreeCleanupSettings settings) => _ref
      .read(appPreferencesProvider)
      .write(
        WorktreeCleanupKeys.settings,
        jsonEncode(
          settings
              .copyWith(changedAt: _ref.read(clockProvider).nowUtc())
              .toJson(),
        ),
      );

  /// A dry run at the server: removes nothing, writes nothing.
  Future<WorktreeCleanupReport> preview() =>
      _ref.read(gitDataProvider).previewCleanup();

  /// A real sweep at the server under the current setting — or the one
  /// already running there.
  Future<WorktreeCleanupReport> sweep() =>
      _ref.read(gitDataProvider).sweepCleanup();
}

final worktreeCleanupControllerProvider = Provider<WorktreeCleanupController>(
  WorktreeCleanupController.new,
);
