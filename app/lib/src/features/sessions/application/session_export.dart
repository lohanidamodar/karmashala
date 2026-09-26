/// Handing a session to somebody else — a bug report, an issue, an archive of
/// how a change was made.
///
/// Karmashala already holds every part of this and offers none of it as one
/// thing: the transcript lives in the CLI's own store, the decisions and
/// snapshots live in Karmashala's database, and the checkout is a path. An
/// export is a formatter, not a new source of truth, and it says in the archive
/// itself which parts it could read and which it could not — the same rule the
/// handoff packet follows, for the same reason.
library;

import '../../workspaces/data/workspace_data.dart';
import 'dart:convert';

import 'package:agent_cli/read.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import '../../checkpoints/application/checkpoint_providers.dart'
    show checkpointDaoProvider;
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_working_directory.dart';

/// How many transcript turns an export quotes. High enough that a whole
/// working session fits; bounded, because an archive nobody can open helps
/// nobody. What is left out is counted and said, never silently dropped.
const int kExportTurnLimit = 4000;

/// What an export produced, and what it could not.
class SessionExport {
  const SessionExport({
    required this.fileName,
    required this.entries,
    required this.turns,
    required this.omittedTurns,
    required this.transcriptRefusal,
  });

  /// `port-the-importer-a4f1c2.zip` — the title, so a folder of these reads.
  final String fileName;
  final List<ZipEntry> entries;

  /// Turns written to `transcript.md`.
  final int turns;

  /// Turns the budget left out.
  final int omittedTurns;

  /// Why there is no transcript, or null when there is one. A separate thing
  /// from an empty conversation, which is a real answer.
  final String? transcriptRefusal;

  /// The archive's bytes, built on demand so a caller can inspect the entries
  /// without paying for the deflate.
  List<int> get bytes => buildZipArchive(entries);
}

/// Assembles a session's archive. Best-effort throughout: a part that cannot
/// be read becomes a sentence in the archive rather than a thrown export.
class SessionExporter {
  SessionExporter(this._ref);

  final Ref _ref;
  static final _log = AppLogger.named('sessions.export');

  /// Builds the export for [sessionId]. Throws only when the session is gone.
  Future<SessionExport> build(String sessionId) async {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');

    final now = _ref.read(clockProvider).nowUtc();
    final agentId = _ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final agentName = agentId == null
        ? null
        : _ref.read(agentRegistryProvider).displayNameFor(agentId);
    final repository = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    final directory = sessionWorkingDirectory(_ref, sessionId);

    final transcript = await _transcript(session, agentId);
    final decisions = _decisions(sessionId);
    final checkpoints = _checkpoints(sessionId);

    final entries = <ZipEntry>[
      ZipEntry.text(
        'README.md',
        _readme(
          session: session,
          agentName: agentName,
          at: now,
          transcript: transcript,
          decisions: decisions.length,
          checkpoints: checkpoints.length,
        ),
      ),
      ZipEntry.text(
        'session.json',
        _json({
          'exportedAt': now.toIso8601String(),
          'exportedBy': 'Karmashala',
          'session': {
            'id': session.id,
            'title': session.title,
            'status': session.status.name,
            'createdAt': session.createdAt.toIso8601String(),
            'archivedAt': session.archivedAt?.toIso8601String(),
            'agentId': agentId,
            'agentName': agentName,
            'conversationId': session.externalSessionId,
            'permissionMode': session.permissionMode,
            'modelId': session.modelId,
            'surface': session.surface.name,
            'parentSessionId': session.parentSessionId,
            'parentLink': session.parentLink?.name,
            'usesWorktree': session.useWorktree,
          },
          'checkout': {
            'repositoryId': session.repositoryId,
            'name': repository?.name,
            'environmentId': repository?.path.environmentId,
            'path': repository?.path.path,
            'workingDirectory': directory?.path,
            'worktree': session.worktree?.path,
          },
          'transcript': {
            'turns': transcript.turns.length,
            'omitted': transcript.omitted,
            'refusal': transcript.refusal,
            'toolCallsIncluded': false,
          },
          'decisions': [
            for (final decision in decisions) _decisionJson(decision),
          ],
          'checkpoints': [
            for (final checkpoint in checkpoints)
              {
                'id': checkpoint.id,
                'label': checkpoint.label,
                'takenAt': checkpoint.createdAt.toIso8601String(),
                'sequence': checkpoint.sequence,
                'files': checkpoint.files.length,
              },
          ],
        }),
      ),
      ZipEntry.text('transcript.md', _transcriptMarkdown(session, transcript)),
      if (decisions.isNotEmpty)
        ZipEntry.text('decisions.md', _decisionsMarkdown(decisions)),
    ];

    _log.info(
      'Exported session $sessionId: ${entries.length} files, '
      '${transcript.turns.length} turns'
      '${transcript.refusal == null ? '' : ' (no transcript: '
                '${transcript.refusal})'}.',
    );
    return SessionExport(
      fileName: exportFileName(session.title, session.id),
      entries: entries,
      turns: transcript.turns.length,
      omittedTurns: transcript.omitted,
      transcriptRefusal: transcript.refusal,
    );
  }

  /// The conversation, or why there is none.
  Future<_Transcript> _transcript(Session session, String? agentId) async {
    final externalId = session.externalSessionId;
    if (agentId == null) {
      return const _Transcript(
        refusal:
            'the agent this session ran on is no longer installed, so '
            'Karmashala could not say which store to read',
      );
    }
    if (externalId == null || externalId.isEmpty) {
      // Not a failure: the CLI never opened a conversation to record.
      return const _Transcript();
    }
    try {
      final path = await _ref
          .read(sessionTranscriptLocatorProvider)
          .locate(agentId: agentId, externalSessionId: externalId);
      if (path == null) {
        return _Transcript(
          refusal:
              'the conversation `$externalId` was not found in the agent\'s '
              'own store, which is where Karmashala reads transcripts from',
        );
      }
      final messages = await readCliTranscript(path, agentId);
      final turns = [
        for (final message in messages)
          if (message.role == 'user' || message.role == 'agent')
            if (message.text.trim().isNotEmpty) message,
      ];
      if (turns.length <= kExportTurnLimit) {
        return _Transcript(turns: turns);
      }
      // The tail, which is the part a reader of a bug report wants.
      return _Transcript(
        turns: turns.sublist(turns.length - kExportTurnLimit),
        omitted: turns.length - kExportTurnLimit,
      );
    } on Object catch (error, stack) {
      _log.warning(
        'Could not read the transcript for ${session.id}.',
        error,
        stack,
      );
      return _Transcript(refusal: 'the transcript could not be read ($error)');
    }
  }

  List<DecisionRecord> _decisions(String sessionId) {
    try {
      return _ref.read(sessionRecordsProvider).decisionsFor(sessionId);
    } on Object {
      return const [];
    }
  }

  List<Checkpoint> _checkpoints(String sessionId) {
    try {
      return _ref.read(checkpointDaoProvider).forSession(sessionId);
    } on Object {
      return const [];
    }
  }

  static Map<String, Object?> _decisionJson(DecisionRecord decision) => {
    'sequence': decision.sequence,
    'kind': decision.kind.name,
    'summary': decision.summary,
    'detail': decision.detail,
    'decidedBy': decision.decidedBy,
    'origin': decision.origin.name,
    'originId': decision.originId,
    'recordedAt': decision.recordedAt.toIso8601String(),
    'recordedBySessionId': decision.recordedBySessionId,
  };

  static String _json(Map<String, Object?> value) =>
      '${const JsonEncoder.withIndent('  ').convert(value)}\n';

  /// The page somebody opens first: what this is, and — as plainly — what is
  /// not in it, so nothing here can be mistaken for the whole story.
  static String _readme({
    required Session session,
    required String? agentName,
    required DateTime at,
    required _Transcript transcript,
    required int decisions,
    required int checkpoints,
  }) {
    final out = StringBuffer()
      ..writeln('# ${session.title}')
      ..writeln()
      ..writeln(
        'A Karmashala session, exported ${_stamp(at)} — a copy of what '
        'Karmashala recorded, not a live link to it.',
      )
      ..writeln()
      ..writeln('| | |')
      ..writeln('| --- | --- |')
      ..writeln('| Session | `${session.id}` |')
      ..writeln('| Agent | ${agentName ?? 'no longer installed'} |')
      ..writeln(
        '| Conversation | '
        '${session.externalSessionId == null ? 'none recorded' : '`${session.externalSessionId}`'} |',
      )
      ..writeln('| Started | ${_stamp(session.createdAt)} |')
      ..writeln('| Status | ${session.status.name} |')
      ..writeln()
      ..writeln('## What is in here')
      ..writeln()
      ..writeln(
        '- `session.json` — everything above, and the records below, '
        'as data.',
      )
      ..writeln('- `transcript.md` — ${transcript.describe()}')
      ..writeln(
        '- `decisions.md` — ${decisions == 0 ? 'absent: nothing was recorded '
                  'in this session\'s decision record.' : '$decisions recorded '
                  'decision(s), oldest first.'}',
      )
      ..writeln()
      ..writeln('## What is **not** in here')
      ..writeln()
      ..writeln(
        '- **The files.** No working tree, no diff and no checkpoint '
        'contents. ${checkpoints == 0 ? 'This session recorded no snapshots.' : '$checkpoints snapshot(s) are *listed* in `session.json`, but they '
                  'live in the checkout this was exported from and cannot be '
                  'restored from this archive.'}',
      )
      ..writeln(
        '- **Tool calls.** `transcript.md` holds what the user and the agent '
        'said. What the agent ran is in the CLI\'s own store, not here.',
      )
      ..writeln(
        '- **Anything the agent did not write down.** An export is a record of '
        'what was recorded, which is not the same as what happened.',
      );
    return out.toString();
  }

  static String _transcriptMarkdown(Session session, _Transcript transcript) {
    final out = StringBuffer()
      ..writeln('# ${session.title} — conversation')
      ..writeln();
    final refusal = transcript.refusal;
    if (refusal != null) {
      out.writeln(
        'There is no transcript in this export, because $refusal. **This is '
        'not the same as nothing having been said.**',
      );
      return out.toString();
    }
    if (transcript.turns.isEmpty) {
      out.writeln('Nothing was said in this session.');
      return out.toString();
    }
    if (transcript.omitted > 0) {
      out
        ..writeln(
          '_The last ${transcript.turns.length} of '
          '${transcript.turns.length + transcript.omitted} turns. The '
          '${transcript.omitted} earlier ones are not in this file._',
        )
        ..writeln();
    }
    for (final message in transcript.turns) {
      final who = message.role == 'user' ? 'User' : 'Agent';
      final at = message.at;
      out
        ..writeln('## $who${at == null ? '' : ' · ${_stamp(at)}'}')
        ..writeln()
        ..writeln(message.text.trim())
        ..writeln();
    }
    return out.toString();
  }

  static String _decisionsMarkdown(List<DecisionRecord> decisions) {
    final out = StringBuffer()
      ..writeln('# Decisions recorded in this session')
      ..writeln()
      ..writeln(
        '_Oldest first. Each one keeps who decided it and when; a decision '
        'carried here from an earlier session says which session that was._',
      )
      ..writeln();
    for (final decision in decisions) {
      out
        ..writeln('## ${decision.sequence}. ${decision.kind.name}')
        ..writeln()
        ..writeln(decision.summary);
      final detail = decision.detail;
      if (detail != null && detail.trim().isNotEmpty) {
        out
          ..writeln()
          ..writeln(detail.trim());
      }
      out
        ..writeln()
        ..writeln(
          '_${decision.decidedBy ?? 'decided by: not recorded'} · '
          '${_stamp(decision.recordedAt)} · from ${decision.origin.name}'
          '${decision.originId == null ? '' : ' `${decision.originId}`'}_',
        )
        ..writeln();
    }
    return out.toString();
  }

  static String _stamp(DateTime at) {
    final utc = at.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)}Z';
  }
}

/// The archive's file name: the title, kebabed, with the session id so two
/// exports of two sessions with one title are still two files.
String exportFileName(String title, String sessionId) {
  final slug = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final stem = slug.isEmpty ? 'session' : slug;
  final short = sessionId.length <= 8 ? sessionId : sessionId.substring(0, 8);
  return '${stem.length > 60 ? stem.substring(0, 60) : stem}-$short.zip';
}

/// What could be read of a conversation, and why not when it could not.
class _Transcript {
  const _Transcript({this.turns = const [], this.omitted = 0, this.refusal});

  final List<TranscriptMessage> turns;
  final int omitted;
  final String? refusal;

  /// The README's one line about this file.
  String describe() {
    final refusal = this.refusal;
    if (refusal != null) {
      return '**absent** — $refusal. This is not the same as nothing having '
          'been said.';
    }
    if (turns.isEmpty) return 'empty: nothing was said in this session.';
    return omitted == 0
        ? '${turns.length} turn(s), oldest first.'
        : 'the last ${turns.length} of ${turns.length + omitted} turns; the '
              '$omitted earlier ones were over the export budget.';
  }
}

final sessionExporterProvider = Provider<SessionExporter>(SessionExporter.new);
