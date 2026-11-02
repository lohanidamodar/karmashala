import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';

/// **What a client may see of the bot.** Every reply and every told change
/// passes through this on its way to a link, so the one rule lives in one
/// place: the store stays complete for the server, and a client sees no bot
/// row, no bot project, and nothing about them, unless it asked to follow the
/// bot (`bot.subscribe`) — and then only the bot's own changes, never as a
/// row a list would pick up.
///
/// A session the bot started reaches every client with no parent and with
/// `viaBot`: whatever folds a child under its parent has nothing to fold.
///
/// A new change that names a session must be added to [_sessionOf].
final class BotView {
  BotView._(this.rows, this.projects, this.repositories);

  /// What is hidden now, read from the store in three indexed statements.
  factory BotView.of(AppDatabase database) {
    final rows = SessionDao(database).botIds();
    final projects = {
      for (final row in database.query(
        'SELECT id FROM projects WHERE kind = ?;',
        [Project.botKind],
      ))
        row['id']! as String,
    };
    final repositories = <String>{};
    if (projects.isNotEmpty) {
      final marks = List.filled(projects.length, '?').join(', ');
      for (final row in database.query(
        'SELECT id FROM repositories WHERE project_id IN ($marks);',
        projects.toList(),
      )) {
        repositories.add(row['id']! as String);
      }
    }
    return BotView._(rows, projects, repositories);
  }

  /// Every bot row, a cleared one's too.
  final Set<String> rows;
  final Set<String> projects;
  final Set<String> repositories;

  bool get isEmpty => rows.isEmpty && projects.isEmpty;

  /// [row] as a client reads it: a bot parent is no parent.
  Session row(Session row) {
    final parent = row.parentSessionId;
    if (parent == null || !rows.contains(parent)) return row;
    return Session.fromJson({...row.toJson(), 'viaBot': true}.._dropParent());
  }

  /// [changes] as this link is told them. Nothing is reordered.
  List<DataChange> changes(
    List<DataChange> changes, {
    required bool follower,
  }) => isEmpty
      ? changes
      : [for (final change in changes) ?_change(change, follower: follower)];

  DataChange? _change(DataChange change, {required bool follower}) {
    switch (change) {
      case SessionRowChanged(:final session):
        if (rows.contains(session.id)) {
          return follower ? BotRowChanged(session) : null;
        }
        return SessionRowChanged(row(session));
      case ProjectChanged(:final project) when projects.contains(project.id):
        return null;
      case ProjectRemoved(:final id) when projects.contains(id):
        return null;
      case RepositoryChanged(:final repository)
          when repositories.contains(repository.id):
        return null;
      case RepositoryRemoved(:final id) when repositories.contains(id):
        return null;
      case ImportedChanged(:final session)
          when repositories.contains(session.repositoryId):
        return null;
      case BotRowChanged() || BotApprovalChanged() || BotAgentChanged():
        return follower ? change : null;
      case InboxChanged(:final snapshot) when !follower:
        return InboxChanged(this.snapshot(snapshot));
      case ActivityAppended(:final entries):
        final kept = _entries(entries);
        if (kept.isEmpty) return null;
        return kept.length == entries.length ? change : ActivityAppended(kept);
      default:
        final id = _sessionOf(change);
        if (id == null || !rows.contains(id)) return change;
        return follower && _followerSees(change) ? change : null;
    }
  }

  /// What a follower's panel draws. Rows of the store that a client would
  /// file in a list stay away from it too.
  static bool _followerSees(DataChange change) => switch (change) {
    SessionLinksChanged() ||
    SessionRowRemoved() ||
    RecapChanged() ||
    RecapRemoved() ||
    DecisionRecorded() ||
    FollowUpChanged() ||
    ActivityAppended() ||
    AutomationOriginChanged() => false,
    _ => true,
  };

  /// The session row [change] is about, or null when it is about none.
  static String? _sessionOf(DataChange change) => switch (change) {
    SessionRowRemoved(:final id) => id,
    SessionLinksChanged(:final sessionId) => sessionId,
    DecisionRecorded(:final decision) => decision.sessionId,
    RecapChanged(:final recap) => recap.sessionId,
    RecapRemoved(:final sessionId) => sessionId,
    FollowUpChanged(:final followUp) => followUp.sessionId,
    SessionModesChanged(:final sessionId) => sessionId,
    SessionConfigOptionsChanged(:final sessionId) => sessionId,
    SessionUsageChanged(:final sessionId) => sessionId,
    SessionActiveModelChanged(:final sessionId) => sessionId,
    SessionQueueChanged(:final sessionId) => sessionId,
    SessionAgentChanged(:final sessionId) => sessionId,
    SessionCommandsChanged(:final sessionId) => sessionId,
    SessionNoticed(:final sessionId) => sessionId,
    SessionPromptKindsChanged(:final sessionId) => sessionId,
    TranscriptChanged(:final sessionId) => sessionId,
    ArtifactChanged(:final artifact) => artifact.sessionId,
    VisualChanged(:final visual) => visual.sessionId,
    CheckpointRecorded(:final checkpoint) => checkpoint.sessionId,
    CheckpointsPruned(:final sessionId) => sessionId,
    CheckpointSkipChanged(:final sessionId) => sessionId,
    AutomationOriginChanged(:final sessionId) => sessionId,
    SessionStatusChanged(:final entry) => entry.openId,
    SessionStatusRemoved(:final openId) => openId,
    AttentionNewsTold(:final news) => news.session.openId,
    InboxOpenWanted(:final openId) => openId,
    UsageLimitNoticed(:final notice) => notice.sessionId,
    OpenSessionTab(:final sessionId) => sessionId,
    DraftForSession(:final sessionId) => sessionId,
    _ => null,
  };

  /// A reply as this link reads it: every answer that lists or names a
  /// session passes here. Anything else is told as it is.
  Object? result(Object? value, {required bool follower}) {
    if (isEmpty) return value;
    return switch (value) {
      final Session row => this.row(row),
      final SessionStarted started => SessionStarted(
        session: row(started.session),
        launch: started.launch,
        external: started.external,
        adopted: started.adopted,
        workingDirectoryNotice: started.workingDirectoryNotice,
        credentialNotice: started.credentialNotice,
        depth: started.depth,
        switchNotice: started.switchNotice,
        wait: started.wait,
      ),
      final SessionsSnapshot sessions => _sessions(sessions),
      final WorkspaceSnapshot workspace => _workspace(workspace),
      final ActivityPage page => ActivityPage(
        entries: _entries(page.entries),
        next: page.next,
      ),
      final StatusSnapshot status when !follower => StatusSnapshot(
        entries: [
          for (final entry in status.entries)
            if (!rows.contains(entry.openId)) entry,
        ],
        coverage: status.coverage,
      ),
      final AttentionSnapshot attention when !follower => snapshot(attention),
      _ => value,
    };
  }

  /// [attention] without the bot's items.
  AttentionSnapshot snapshot(AttentionSnapshot attention) => AttentionSnapshot(
    inbox: AttentionInbox(
      items: [
        for (final item in attention.inbox.items)
          if (!rows.contains(item.session.openId)) item,
      ],
    ),
    waiting: [
      for (final waiting in attention.waiting)
        if (!rows.contains(waiting.session.openId)) waiting,
    ],
  );

  SessionsSnapshot _sessions(SessionsSnapshot all) => SessionsSnapshot(
    sessions: [
      for (final session in all.sessions)
        if (!rows.contains(session.id)) row(session),
    ],
    links: {
      for (final MapEntry(key: id, value: links) in all.links.entries)
        if (!rows.contains(id)) id: links,
    },
    imported: [
      for (final session in all.imported)
        if (!repositories.contains(session.repositoryId)) session,
    ],
    decisions: [
      for (final decision in all.decisions)
        if (!rows.contains(decision.sessionId)) decision,
    ],
    recaps: [
      for (final recap in all.recaps)
        if (!rows.contains(recap.sessionId)) recap,
    ],
    followUps: [
      for (final followUp in all.followUps)
        if (!rows.contains(followUp.sessionId)) followUp,
    ],
  );

  WorkspaceSnapshot _workspace(WorkspaceSnapshot all) => WorkspaceSnapshot(
    workspaces: all.workspaces,
    projects: [
      for (final project in all.projects)
        if (!projects.contains(project.id)) project,
    ],
    repositories: [
      for (final repository in all.repositories)
        if (!repositories.contains(repository.id)) repository,
    ],
    sections: all.sections,
  );

  List<ActivityEntry> _entries(List<ActivityEntry> entries) => [
    for (final entry in entries)
      if (!rows.contains(entry.sessionId)) entry,
  ];
}

extension on Map<String, Object?> {
  void _dropParent() {
    remove('parentSessionId');
    remove('parentLink');
  }
}
