import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/detected_session.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import 'session_engine_provider.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';

/// Rename/delete operations available for **every** session in the app — native
/// engine sessions and imported CLI sessions alike. Imported operations also
/// propagate to the originating CLI store (best-effort).
class SessionActions {
  SessionActions(this._ref);
  final Ref _ref;

  void renameNative(String id, String title) {
    _ref.read(sessionDaoProvider).updateTitle(id, title);
    _bump();
  }

  void deleteNative(String id) {
    _ref.read(sessionDaoProvider).delete(id);
    if (_ref.read(selectedSessionIdProvider) == id) {
      _ref.read(selectedSessionIdProvider.notifier).select(null);
    }
    _bump();
  }

  Future<void> renameImported(ImportedSession session, String title) async {
    _ref.read(importedSessionDaoProvider).updateTitle(session.id, title);
    try {
      await _ref
          .read(cliSessionMutatorProvider)
          .rename(_toDetected(session), title);
    } catch (_) {
      // CLI store unavailable — the workspace title is still updated.
    }
    _bump();
  }

  Future<void> deleteImported(ImportedSession session) async {
    _ref.read(importedSessionDaoProvider).delete(session.id);
    try {
      await _ref.read(cliSessionMutatorProvider).delete(_toDetected(session));
    } catch (_) {}
    if (_ref.read(selectedImportedSessionIdProvider) == session.id) {
      _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    }
    _bump();
  }

  /// Resumes an imported CLI session as a new native engine session, launching
  /// the agent with `--resume` and the per-agent "existing sessions" permission.
  /// Throws if the repository or a matching agent installation is missing.
  Future<void> resumeImported(ImportedSession session) async {
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) {
      throw StateError(
        'Repository for this session is no longer in the workspace.',
      );
    }
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(session.environmentId)
        .where((i) => i.agentKind == session.cli)
        .toList();
    if (installs.isEmpty) {
      throw StateError(
        'No ${session.cli.name} installation in ${session.environmentId}. '
        'Run "Discover agents" in Settings first.',
      );
    }
    final permission = _ref
        .read(settingsControllerProvider)
        .permissionsFor(session.cli)
        .existingSessions;
    final started = await _ref
        .read(sessionEngineProvider)
        .start(
          repository: repo,
          installation: installs.first,
          title: 'Resume: ${session.displayTitle}',
          resumeSessionId: session.externalId,
          permissionMode: permission,
        );
    _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    _ref.read(selectedSessionIdProvider.notifier).select(started.id);
    _bump();
  }

  DetectedSession _toDetected(ImportedSession session) => DetectedSession(
    cli: session.cli,
    sessionId: session.externalId,
    cwd: EnvironmentPath(environmentId: session.environmentId, path: ''),
    filePath: session.filePath,
    storeHome: session.storeHome,
  );

  void _bump() => _ref.read(sessionsRevisionProvider.notifier).bump();
}

final sessionActionsProvider = Provider<SessionActions>(
  (ref) => SessionActions(ref),
);
