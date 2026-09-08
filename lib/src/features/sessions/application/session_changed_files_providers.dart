import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/path_translator.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_ids.dart';
import '../../checkpoints/data/checkpoint_dao.dart';
import '../../checkpoints/domain/checkpoint.dart';
import '../../cli_detection/application/codex_app_server_providers.dart';
import '../../cli_detection/data/codex_thread.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../git/data/file_edit_reader.dart';
import '../../git/domain/file_change.dart';
import '../../git/domain/file_edit.dart';
import '../domain/session.dart';
import '../domain/session_changed_files.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// What one session changed, out of the agent's own record where it keeps one
/// and out of git where it does not.
///
/// **Three answers per agent, measured rather than assumed** (2026-09-08):
///
/// * **Codex** keeps the richest record and the app already holds the
///   connection. `thread/turns/list` with `itemsView: 'full'` carries a
///   `fileChange` item per applied patch — see
///   `CodexAppServerClient.listFileChanges`, which pages it so a 15 MB thread
///   never lands in memory whole.
/// * **Claude Code** writes every `Edit`/`Write`/`MultiEdit` into its own JSONL
///   transcript, and `file_edit_reader.dart` already parses one line of it. This
///   streams the file and keeps the path and the kind, dropping the texts each
///   line produced — a `Write` record carries the whole new file.
/// * **Antigravity** keeps nothing readable: its conversation payloads are
///   protobuf in an unpublished schema, which is why `readCliTranscript` refuses
///   it by name. Git is the only source, exactly as the owner specified.
///
/// **The fallback, and the baseline it needs.** Sessions are *not* isolated in
/// worktrees here — agents run in the user's own repository — so a bare
/// `git diff` cannot attribute anything to a session. The one per-session
/// baseline this app already records is the **checkpoint chain**: one
/// `refs/karmashala/checkpoints/<sessionId>` per session, a tree per finished
/// turn, and `session_checkpoint_files` naming what moved between them. It costs
/// no process and no git invocation to read, because it is already in the
/// database. Its honest limit is the first link: that one is measured against
/// the commit the repository was on, so it includes whatever was already dirty.
/// The caveat says so rather than the number pretending otherwise.
///
/// A session with no checkpoint has **no baseline at all**, and that is reported
/// as such instead of being invented.
class SessionChangedFilesService {
  const SessionChangedFilesService(this._ref, {this.translator = const PathTranslator()});

  final Ref _ref;
  final PathTranslator translator;

  Future<SessionChangedFilesReport> read(String sessionId) async {
    final now = _ref.read(clockProvider).nowUtc();
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      return SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.unknownSession,
        checkedAt: now,
      );
    }

    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    final agentId = installation?.agentId;
    final agentName =
        (agentId == null
            ? null
            : _ref.read(agentRegistryProvider).byId(agentId)?.displayName) ??
        agentId ??
        '';
    final environment = installation == null
        ? null
        : _ref
              .read(executionEnvironmentDaoProvider)
              .getById(installation.executable.environmentId);

    final fromAgent = await _fromAgentRecord(session, agentId, environment);
    final files = fromAgent.$1;
    if (files != null) {
      return SessionChangedFilesReport(
        outcome: files.isEmpty
            ? SessionChangedFilesOutcome.agentRecordNamesNoFile
            : SessionChangedFilesOutcome.fromAgentRecord,
        files: files,
        agentName: agentName,
        checkedAt: now,
      );
    }

    final checkpoints = _ref.read(checkpointDaoProvider).forSession(sessionId);
    if (checkpoints.isEmpty) {
      return SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.nothingCanAnswer,
        gap: fromAgent.$2,
        detail: fromAgent.$3,
        agentName: agentName,
        checkedAt: now,
      );
    }
    final fromGit = _fromCheckpoints(checkpoints);
    return SessionChangedFilesReport(
      outcome: fromGit.isEmpty
          ? SessionChangedFilesOutcome.checkpointsNameNoFile
          : SessionChangedFilesOutcome.fromCheckpoints,
      files: fromGit,
      gap: fromAgent.$2,
      detail: fromAgent.$3,
      agentName: agentName,
      checkedAt: now,
    );
  }

  /// The agent's own answer, or null and the reason there is none.
  Future<(List<SessionChangedFile>?, SessionRecordGap, String)>
  _fromAgentRecord(
    Session session,
    String? agentId,
    ExecutionEnvironment? environment,
  ) async {
    switch (agentId) {
      case AgentIds.codex:
        return _fromCodex(session, environment);
      case AgentIds.claudeCode:
        return _fromClaudeTranscript(session, environment);
      default:
        return (null, SessionRecordGap.agentKeepsNoRecord, '');
    }
  }

  Future<(List<SessionChangedFile>?, SessionRecordGap, String)> _fromCodex(
    Session session,
    ExecutionEnvironment? environment,
  ) async {
    final threadId = session.externalSessionId ?? '';
    if (threadId.isEmpty) {
      return (null, SessionRecordGap.noConversationYet, '');
    }
    if (environment == null) {
      return (null, SessionRecordGap.recordUnreadable, 'no environment row');
    }
    // The shared pool, so a workspace that has already renamed a thread pays no
    // spawn at all and one that has not pays exactly one — for the connection,
    // not for this call.
    final client = _ref
        .read(codexAppServersProvider)
        .forEnvironment(environment.id);
    if (client == null) {
      return (
        null,
        SessionRecordGap.recordUnreadable,
        'no Codex to ask on ${environment.name}',
      );
    }
    final result = await client.listFileChanges(threadId);
    final failure = result.failure;
    if (failure != null) {
      return (null, SessionRecordGap.recordUnreadable, failure.message);
    }
    final byPath = <String, SessionChangedFile>{};
    for (final change in result.changes) {
      _record(
        byPath,
        environment,
        path: change.path,
        movedTo: change.movedTo,
        kind: switch (change.kind) {
          CodexFileChangeKind.add => FileEditKind.created,
          CodexFileChangeKind.delete => FileEditKind.deleted,
          // An `update` is a modification; a kind this build does not know is
          // still a change Codex reported, and "modified" is the weaker claim
          // rather than a guess at a new one.
          CodexFileChangeKind.update ||
          CodexFileChangeKind.unknown => FileEditKind.modified,
        },
      );
    }
    return (byPath.values.toList(growable: false), SessionRecordGap.none, '');
  }

  /// Claude Code's own transcript, streamed and reduced to paths as it goes.
  ///
  /// `claudeFileEdits` is called per line and its records are dropped the moment
  /// their path and kind are taken: one `Write` record holds the whole file it
  /// wrote, so collecting them all to draw a list would hold the session's
  /// entire output in memory.
  Future<(List<SessionChangedFile>?, SessionRecordGap, String)>
  _fromClaudeTranscript(
    Session session,
    ExecutionEnvironment? environment,
  ) async {
    final externalId = session.externalSessionId ?? '';
    if (externalId.isEmpty) {
      return (null, SessionRecordGap.noConversationYet, '');
    }
    final path = await _ref
        .read(sessionTranscriptLocatorProvider)
        .locate(agentId: AgentIds.claudeCode, externalSessionId: externalId);
    if (path == null) {
      return (
        null,
        SessionRecordGap.recordUnreadable,
        'no transcript for this conversation in any store we can read',
      );
    }
    final byPath = <String, SessionChangedFile>{};
    try {
      await for (final line
          in File(path)
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        final Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, Object?>) continue;
        for (final edit in claudeFileEdits(decoded)) {
          _record(byPath, environment, path: edit.path, kind: edit.kind);
        }
      }
    } on Object catch (error) {
      return (null, SessionRecordGap.recordUnreadable, '$error');
    }
    return (byPath.values.toList(growable: false), SessionRecordGap.none, '');
  }

  /// Every path any checkpoint of this session named, oldest chain first.
  ///
  /// Repository-relative, because that is how `git diff --name-status` names
  /// them and how the Changes panel shows them; [SessionChangedFile.hostPath]
  /// stays null rather than a join this reading cannot make safely for a tree on
  /// another filesystem.
  ///
  /// **No rename ever arrives here**, and that is the chain's shape rather than
  /// an omission: `CheckpointService` asks git with `--no-renames`, so a moved
  /// file is recorded as a delete and an add, and `session_checkpoint_files`
  /// stores only `(path, status)` with nowhere to keep an old name. Codex's
  /// `move_path` is the one source that can say a file moved.
  List<SessionChangedFile> _fromCheckpoints(List<Checkpoint> checkpoints) {
    final byPath = <String, SessionChangedFile>{};
    for (final checkpoint in checkpoints) {
      for (final file in checkpoint.files) {
        _record(
          byPath,
          null,
          path: file.path,
          kind: switch (file.type) {
            FileChangeType.added || FileChangeType.untracked =>
              FileEditKind.created,
            FileChangeType.deleted => FileEditKind.deleted,
            // Everything else is "not what HEAD has", which is the true weaker
            // claim for a copy or a status letter we do not name.
            _ => FileEditKind.modified,
          },
        );
      }
    }
    return byPath.values.toList(growable: false);
  }

  /// Folds one path into [byPath], keeping the **strongest** claim made about
  /// it: a file this session created stays created however often it was edited
  /// afterwards, and one it deleted stays deleted.
  void _record(
    Map<String, SessionChangedFile> byPath,
    ExecutionEnvironment? environment, {
    required String path,
    required FileEditKind kind,
    String? movedTo,
  }) {
    final existing = byPath[path];
    final winner = existing == null
        ? kind
        : (_rank(kind) >= _rank(existing.kind) ? kind : existing.kind);
    byPath[path] = SessionChangedFile(
      path: path,
      hostPath: _hostSpellingOf(path, environment),
      kind: winner,
      movedTo: movedTo ?? existing?.movedTo,
    );
  }

  static int _rank(FileEditKind kind) => switch (kind) {
    FileEditKind.modified => 0,
    FileEditKind.created => 1,
    FileEditKind.deleted => 2,
  };

  /// [path] as this host spells it, or null when it cannot be expressed here.
  ///
  /// The one translator (`core/process/path_translator.dart`), never a second
  /// one. An SSH path is deliberately not translated: it names a file on another
  /// machine, and a stat of ours is not evidence either way — the same rule §20
  /// applies to a remote executable.
  String? _hostSpellingOf(String path, ExecutionEnvironment? environment) {
    if (environment == null) return null;
    switch (environment.kind) {
      case EnvironmentKind.windowsNative:
      case EnvironmentKind.localPosix:
        return path;
      case EnvironmentKind.ssh:
        return null;
      case EnvironmentKind.wsl:
        final windows = _ref
            .read(executionEnvironmentDaoProvider)
            .getAll()
            .where((e) => e.kind == EnvironmentKind.windowsNative)
            .firstOrNull;
        if (windows == null) return null;
        try {
          return translator
              .translate(
                EnvironmentPath(environmentId: environment.id, path: path),
                from: environment,
                to: windows,
              )
              .path;
        } on PathTranslationException {
          return null;
        }
    }
  }
}

final sessionChangedFilesServiceProvider =
    Provider<SessionChangedFilesService>(
      (ref) => SessionChangedFilesService(ref),
    );

/// What a session changed, read once per opening of the surface that asks.
///
/// `autoDispose` and watched by nothing else. **Nothing polls this** — it is
/// read when the surface opens and when the user asks for it again, which is
/// §19's third rule and the reason a Codex reading costs a call rather than a
/// call every few seconds.
final sessionChangedFilesProvider = FutureProvider.autoDispose
    .family<SessionChangedFilesReport, String>((ref, sessionId) {
      // This row only: the conversation a session points at is what the answer
      // is about, and a launch or a rename anywhere else must not re-read it.
      ref.watchSession(sessionId);
      return ref.read(sessionChangedFilesServiceProvider).read(sessionId);
    });
