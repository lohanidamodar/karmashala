import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AgentFileChangesReading, DataRefusalCode, DataRefused;
import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import '../../checkpoints/data/checkpoints_data.dart';
import '../../cli_detection/application/agent_store_server_providers.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import '../data/server_transcripts.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// What one session changed: the agent's own record where it keeps one, else
/// the checkpoint chain, whose first link includes whatever was already dirty.
class SessionChangedFilesService {
  const SessionChangedFilesService(
    this._ref, {
    this.translator = const PathTranslator(),
  });

  final Ref _ref;
  final PathTranslator translator;

  Future<SessionChangedFilesReport> read(String sessionId) async {
    final now = _ref.read(clockProvider).nowUtc();
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) {
      return SessionChangedFilesReport(
        outcome: SessionChangedFilesOutcome.unknownSession,
        checkedAt: now,
      );
    }

    final installation = _ref
        .read(agentInstallationsDataProvider)
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
              .read(environmentsDataProvider)
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

    final checkpoints = await _ref
        .read(checkpointsDataProvider)
        .forSession(sessionId);
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

  /// The agent's own answer, or null and the reason there is none — asked of
  /// the kind of record its adapter declares, never of who the agent is.
  Future<(List<SessionChangedFile>?, SessionRecordGap, String)>
  _fromAgentRecord(
    Session session,
    String? agentId,
    ExecutionEnvironment? environment,
  ) async {
    final record = agentId == null
        ? null
        : _ref.read(agentRegistryProvider).adapterFor(agentId)?.fileChanges;
    if (record != null && _ref.read(capabilitiesProvider).changedFilesViaServer) {
      final fromServer = await _fromServer(session.id, environment);
      if (fromServer != null) return fromServer;
    }
    return switch (record) {
      StoreServerFileChanges() => _fromStoreServer(
        session,
        agentId!,
        environment,
      ),
      TranscriptFileEdits(:final editsOnLine) => _fromTranscript(
        session,
        agentId!,
        environment,
        editsOnLine,
      ),
      null => (null, SessionRecordGap.agentKeepsNoRecord, ''),
    };
  }

  /// The server's reading of the agent's record, where the record is (Stage 0
  /// step 7), or null for a server that does not know the request.
  Future<(List<SessionChangedFile>?, SessionRecordGap, String)?> _fromServer(
    String sessionId,
    ExecutionEnvironment? environment,
  ) async {
    final AgentFileChangesReading reading;
    try {
      reading = await _ref
          .read(serverTranscriptsProvider)
          .changedFiles(sessionId);
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.invalid) return null;
      return (null, SessionRecordGap.recordUnreadable, refusal.message);
    } on Object catch (error) {
      return (null, SessionRecordGap.recordUnreadable, '$error');
    }
    final changes = reading.changes;
    if (changes == null) return (null, reading.gap, reading.detail);
    final byPath = <String, SessionChangedFile>{};
    for (final change in changes) {
      _record(
        byPath,
        environment,
        path: change.path,
        movedTo: change.movedTo,
        kind: change.kind,
      );
    }
    return (byPath.values.toList(growable: false), SessionRecordGap.none, '');
  }

  /// The agent's store server, asked for the conversation's file changes.
  Future<(List<SessionChangedFile>?, SessionRecordGap, String)>
  _fromStoreServer(
    Session session,
    String agentId,
    ExecutionEnvironment? environment,
  ) async {
    final conversationId = session.externalSessionId ?? '';
    if (conversationId.isEmpty) {
      return (null, SessionRecordGap.noConversationYet, '');
    }
    if (environment == null) {
      return (null, SessionRecordGap.recordUnreadable, 'no environment row');
    }
    // The shared pool: a workspace that has already renamed a conversation
    // pays no spawn at all, and one that has not pays exactly one — for the
    // connection.
    final client = _ref
        .read(agentStoreServersProvider)
        .forEnvironment(environment.id, agentId);
    if (client == null) {
      final name =
          _ref
              .read(agentRegistryProvider)
              .adapterFor(agentId)
              ?.presentation
              .shortName ??
          agentId;
      return (
        null,
        SessionRecordGap.recordUnreadable,
        'no $name to ask on ${environment.name}',
      );
    }
    final result = await client.listFileChanges(conversationId);
    final failure = result.failure;
    if (failure != null) {
      return (null, SessionRecordGap.recordUnreadable, failure);
    }
    final byPath = <String, SessionChangedFile>{};
    for (final change in result.changes) {
      _record(
        byPath,
        environment,
        path: change.path,
        movedTo: change.movedTo,
        kind: change.kind,
      );
    }
    return (byPath.values.toList(growable: false), SessionRecordGap.none, '');
  }

  /// The agent's transcript, streamed and reduced to paths as it goes.
  Future<(List<SessionChangedFile>?, SessionRecordGap, String)> _fromTranscript(
    Session session,
    String agentId,
    ExecutionEnvironment? environment,
    List<FileEditRecord> Function(Map<String, Object?> json) editsOnLine,
  ) async {
    final externalId = session.externalSessionId ?? '';
    if (externalId.isEmpty) {
      return (null, SessionRecordGap.noConversationYet, '');
    }
    final path = await _ref
        .read(sessionTranscriptLocatorProvider)
        .locate(agentId: agentId, externalSessionId: externalId);
    if (path == null) {
      return (
        null,
        SessionRecordGap.recordUnreadable,
        'no transcript for this conversation in any store we can read',
      );
    }
    final byPath = <String, SessionChangedFile>{};
    try {
      await for (final line in File(
        path,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        final Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, Object?>) continue;
        for (final edit in editsOnLine(decoded)) {
          _record(byPath, environment, path: edit.path, kind: edit.kind);
        }
      }
    } on Object catch (error) {
      return (null, SessionRecordGap.recordUnreadable, '$error');
    }
    return (byPath.values.toList(growable: false), SessionRecordGap.none, '');
  }

  /// Every path any checkpoint of this session named, oldest first. **No rename
  /// arrives here**: `CheckpointService` asks git with `--no-renames`.
  List<SessionChangedFile> _fromCheckpoints(List<Checkpoint> checkpoints) {
    final byPath = <String, SessionChangedFile>{};
    for (final checkpoint in checkpoints) {
      for (final file in checkpoint.files) {
        _record(
          byPath,
          null,
          path: file.path,
          kind: switch (file.type) {
            FileChangeType.added ||
            FileChangeType.untracked => FileEditKind.created,
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

  /// Folds one path into [byPath], keeping the **strongest** claim: created
  /// stays created however often it was edited, and deleted stays deleted.
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

  /// [path] as this host spells it, or null. An SSH path is deliberately not
  /// translated: a stat of ours is not evidence about another machine.
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
            .read(environmentsDataProvider)
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

final sessionChangedFilesServiceProvider = Provider<SessionChangedFilesService>(
  (ref) => SessionChangedFilesService(ref),
);

/// What a session changed, read once per opening of the surface that asks —
/// **nothing polls this**, which is why a Codex reading costs one call.
final sessionChangedFilesProvider = FutureProvider.autoDispose
    .family<SessionChangedFilesReport, String>((ref, sessionId) {
      // This row only: the conversation a session points at is what the answer
      // is about, and a launch or a rename anywhere else must not re-read it.
      ref.watchSession(sessionId);
      return ref.read(sessionChangedFilesServiceProvider).read(sessionId);
    });
