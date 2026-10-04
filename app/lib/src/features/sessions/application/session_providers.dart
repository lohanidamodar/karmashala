import 'dart:async';

import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/keyed_replica.dart';
import '../../workspaces/data/workspace_data.dart';
import '../data/sessions_data.dart';
import 'session_decision_providers.dart';
import 'session_repositories_service.dart';
import 'session_signals.dart';
import 'superseded_history.dart';

/// The sessions as the server keeps them, read from this app's copy and
/// written through the server. Also where the server's own word on a row —
/// a status the daemon recorded, a session a phone started, another client's
/// rename — becomes a [SessionChange]: this app's own writes are announced
/// by their writers, as they always were.
final sessionsDataProvider = Provider<SessionsData>((ref) {
  final client = ref.watch(dataClientProvider);
  final data = SessionsData(client);
  void notify(SessionChange change) =>
      ref.read(sessionsRevisionProvider.notifier).changed(change);
  // Held while a batch is taken in, then published as one: a project deleted
  // elsewhere, with its hundred sessions, wakes each watcher once.
  final held = <SessionChange>[];
  void publish(SessionChange? change, {bool overridesLocal = false}) {
    if (change == null) return;
    // This app's own write: its writer announced it, as it always did —
    // unless the server's answer is not what it wrote (a status it records
    // itself, ignored), and the copy rolled back under the writer's signal.
    if (client.applyingOwnAnswer && !overridesLocal) return;
    client.applyingBatch ? held.add(change) : notify(change);
  }

  final subscriptions = <StreamSubscription<Object?>>[
    client.batchEnds.listen((_) {
      if (held.isEmpty) return;
      final merged = mergedSessionChange(held);
      held.clear();
      notify(merged);
    }),
    client.sessions.serverChanges.listen(
      (change) => publish(
        sessionChangeOf(change),
        overridesLocal: change.overridesLocal,
      ),
    ),
    client.imported.serverChanges.listen(
      (change) => publish(importedChangeOf(change)),
    ),
    // A row the server has just told which conversation it is on — launched
    // or directory attribution — takes the selection off the history it
    // supersedes.
    client.sessions.serverChanges.listen((change) {
      final before = change.before;
      final conversation = change.after?.externalSessionId;
      if (before == null || conversation == null || conversation.isEmpty) {
        return;
      }
      if (before.externalSessionId == conversation) return;
      followSupersededHistory(
        ref,
        change.key,
        conversation,
        importedById: (id) => client.imported[id],
      );
    }),
    // A decision filed elsewhere — a prompt answered from a phone, through
    // the server — reaches the open panel.
    client.decisions.serverChanges.listen(
      (_) => ref.read(decisionsRevisionProvider.notifier).bump(),
    ),
  ];
  ref.onDispose(() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  });
  return data;
});

/// The CLI conversations imported as history.
final importedSessionsProvider = Provider<ImportedSessionsData>(
  (ref) => ImportedSessionsData(
    ref.watch(dataClientProvider),
    ref.watch(sessionsDataProvider),
  ),
);

/// A session's event log, decisions, recap and the relays into it.
final sessionRecordsProvider = Provider<SessionRecordsData>(
  (ref) => SessionRecordsData(ref.watch(dataClientProvider)),
);

/// What sessions left behind.
final followUpsDataProvider = Provider<FollowUpsData>(
  (ref) => FollowUpsData(ref.watch(dataClientProvider)),
);

/// Manages the repositories a session spans (within one project).
final sessionRepositoriesServiceProvider = Provider<SessionRepositoriesService>(
  (ref) => SessionRepositoriesService(
    sessions: ref.watch(sessionsDataProvider),
    workspace: ref.watch(workspaceDataProvider),
  ),
);

/// What the server's word on one row moved, as the narrowest [SessionChange]
/// that says it; null when nothing a watcher reads moved.
SessionChange? sessionChangeOf(ReplicaChange<Session> change) {
  final before = change.before;
  final after = change.after;
  if (before == null && after == null) return null;
  if (before == null) return SessionChange.created(change.key);
  if (after == null) return SessionChange.removed(change.key);
  final kinds = <SessionChangeKind>{
    if (before.title != after.title || before.titleByUser != after.titleByUser)
      SessionChangeKind.title,
    if (before.status != after.status || before.archivedAt != after.archivedAt)
      SessionChangeKind.status,
    if (before.paneId != after.paneId ||
        before.repositoryId != after.repositoryId ||
        before.worktree != after.worktree ||
        before.useWorktree != after.useWorktree ||
        before.workingDirectory != after.workingDirectory ||
        before.externalSessionId != after.externalSessionId ||
        before.agentInstallationId != after.agentInstallationId)
      SessionChangeKind.placement,
    if (before.permissionMode != after.permissionMode ||
        before.modelId != after.modelId ||
        before.view != after.view)
      SessionChangeKind.settings,
  };
  return kinds.isEmpty
      ? null
      : SessionChange(kinds: kinds, sessionId: change.key);
}

/// [changes] as one: every kind any of them touched, and the row when they
/// all named the same one.
SessionChange mergedSessionChange(List<SessionChange> changes) {
  if (changes.length == 1) return changes.single;
  final ids = {for (final c in changes) c.sessionId};
  return SessionChange(
    kinds: {for (final c in changes) ...c.kinds},
    sessionId: ids.length == 1 ? ids.single : null,
  );
}

/// An imported record appearing, going or being renamed, in the words the
/// lists already watch.
SessionChange? importedChangeOf(ReplicaChange<Object> change) {
  if (change.before == null && change.after == null) return null;
  if (change.before == null) return SessionChange.created(change.key);
  if (change.after == null) return SessionChange.removed(change.key);
  return SessionChange.renamed(change.key);
}
