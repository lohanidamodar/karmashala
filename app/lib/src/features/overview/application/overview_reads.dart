import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/stream.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused, TranscriptPage;
import 'package:karmashala_session/transcript.dart'
    show ChatViewEvidence, SessionChatView;
import 'package:karmashala_session/delivery.dart'
    show SessionChangedFilesOutcome;
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_git/git.dart' show FileDiffStat;

import '../../../core/capabilities/capabilities.dart';
import '../../git/data/git_data.dart';
import '../../agents/data/agents_data.dart';
import '../../sessions/application/session_changed_files_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/data/server_transcripts.dart';

/// How long one Overview read waits on the server before saying so.
const Duration kOverviewReadTimeout = Duration(seconds: 15);

/// A session's last answer, or why there is none to show.
@immutable
class LastAnswer {
  const LastAnswer.of(String this.text) : why = null;
  const LastAnswer.missing(String this.why) : text = null;

  static const none = LastAnswer.missing('No answer recorded yet.');

  final String? text;

  /// Said in place of [text]: that there is none, or why it cannot be read.
  final String? why;

  /// The last agent turn with words in [rows], or [none].
  static LastAnswer from(List<TranscriptMessage> rows) {
    for (final row in rows.reversed) {
      if (row.role == 'agent' && row.text.trim().isNotEmpty) {
        return LastAnswer.of(row.text.trim());
      }
    }
    return none;
  }

  @override
  bool operator ==(Object other) =>
      other is LastAnswer && other.text == text && other.why == why;

  @override
  int get hashCode => Object.hash(text, why);
}

/// One call or background run a session has open, as the Overview words it.
@immutable
class OverviewOpenCall {
  const OverviewOpenCall({this.phrase, this.raw, this.since, this.background = false});

  /// What it is doing in words; null when only its command says.
  final String? phrase;

  /// The command itself, for the details disclosure only.
  final String? raw;
  final DateTime? since;
  final bool background;

  @override
  bool operator ==(Object other) =>
      other is OverviewOpenCall &&
      other.phrase == phrase &&
      other.raw == raw &&
      other.since == since &&
      other.background == background;

  @override
  int get hashCode => Object.hash(phrase, raw, since, background);
}

/// What one server read says a session is in the middle of: the plan it
/// stands on and its open calls, oldest first.
@immutable
class OverviewGlance {
  const OverviewGlance({
    this.plan,
    this.open = const [],
    this.messageTimes = const [],
  });

  static const empty = OverviewGlance();

  final AgentPlan? plan;
  final List<OverviewOpenCall> open;

  /// When each message the read held was written, the person's and the
  /// agent's: what "new since you last looked" counts.
  final List<DateTime> messageTimes;

  @override
  bool operator ==(Object other) =>
      other is OverviewGlance &&
      other.plan == plan &&
      _sameCalls(other.open, open) &&
      other.messageTimes.length == messageTimes.length &&
      (messageTimes.isEmpty || other.messageTimes.last == messageTimes.last);

  @override
  int get hashCode =>
      Object.hash(plan, Object.hashAll(open), messageTimes.length);

  static bool _sameCalls(List<OverviewOpenCall> a, List<OverviewOpenCall> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// [page]'s plan and open calls: its own rows, and the digest of the rows
/// before them.
OverviewGlance overviewGlanceOf(TranscriptPage page) {
  final digest = page.digest;
  AgentPlan? plan;
  for (final row in page.messages.reversed) {
    if (row.tool?.plan case final found?) {
      plan = found;
      break;
    }
  }
  plan ??= digest?.plan?.message.tool?.plan;
  bool open(TranscriptMessage row) =>
      row.pendingToolUseId != null ||
      row.pendingBackgroundAgentId != null ||
      (row.background?.state.isRunning ?? false);
  final rows = [
    for (final update in digest?.pending ?? const []) update.message,
    for (final row in page.messages)
      if (open(row)) row,
  ];
  return OverviewGlance(
    plan: plan,
    messageTimes: [
      for (final row in page.messages)
        if ((row.role == 'agent' || row.role == 'user') &&
            row.text.trim().isNotEmpty)
          ?row.at,
    ],
    open: [
      for (final row in rows)
        if (row.tool case final tool?)
          OverviewOpenCall(
            phrase:
                toolDoingPhrase(tool) ??
                switch (row.background?.description) {
                  final named? when !looksLikeCommand(named) => named,
                  _ => null,
                },
            // A call with no words for it is named only by its subject,
            // which is shown folded away.
            raw: toolDoingPhrase(tool) == null ? tool.subject : null,
            since: row.at,
            background:
                row.background != null || row.pendingBackgroundAgentId != null,
          ),
    ],
  );
}

/// Whether [text] reads as a shell command rather than words for a person:
/// more than a line, shell punctuation, a drive path, or a command's shape.
bool looksLikeCommand(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (t.contains('\n') || t.length > 100) return true;
  if (RegExp(r'[$|;&<>`{}]|[A-Za-z]:\\|\s--?[a-z][\w-]*').hasMatch(t)) {
    return true;
  }
  return RegExp(
    r'^(cd|ls|git|gh|flutter|dart|npm|npx|pnpm|yarn|python3?|node|deno|k6|'
    r'tail|cat|grep|rg|find|curl|wget|docker|kubectl|make|cargo|go|pwsh|'
    r'powershell|bash|sh|cmd|wsl|ssh|scp|rm|cp|mv|mkdir|echo|sleep)\b',
  ).hasMatch(t);
}

/// **The Overview's reads of a session's record**: one at a time, never
/// followed. Tests replace it; nothing else here reaches a transcript.
class OverviewReader {
  OverviewReader(this._ref);

  final Ref _ref;

  static bool _answered(List<TranscriptMessage> held) =>
      held.any((m) => m.role == 'agent' && m.text.trim().isNotEmpty);

  /// The last answer of [sessionId]: read where the server keeps the record,
  /// else off this machine's disk for a server too old to read it.
  Future<LastAnswer> lastAnswer(String sessionId) async {
    final caps = _ref.read(capabilitiesProvider);
    try {
      if (caps.turnsViaServer) {
        final served = await serverSessionTurns(
          _ref,
          sessionId,
          spoken: true,
          enough: _answered,
        ).timeout(kOverviewReadTimeout);
        if (served != null) {
          if (served.absence case final absence?) {
            return LastAnswer.missing(_unreadable(absence));
          }
          return LastAnswer.from(served.turns);
        }
      }
      if (caps.chatViaServer) {
        final page = await _ref
            .read(serverTranscriptsProvider)
            .glance(sessionId, limit: 40)
            .timeout(kOverviewReadTimeout);
        if (page.absence case final absence?) {
          return LastAnswer.missing(_unreadable(absence));
        }
        return LastAnswer.from(page.messages);
      }
      return await _fromDisk(sessionId).timeout(kOverviewReadTimeout);
    } on TimeoutException {
      return LastAnswer.missing(
        'The server did not answer within '
        '${kOverviewReadTimeout.inSeconds} s, so the last answer is not shown.',
      );
    } on DataRefused catch (refusal) {
      return LastAnswer.missing(
        'The server could not read this conversation: ${refusal.message}',
      );
    }
  }

  static String _unreadable(ChatViewEvidence absence) =>
      'There is no conversation record to read: '
      '${SessionChatView.read(absence, prior: false).reason}';

  Future<LastAnswer> _fromDisk(String sessionId) async {
    final row = _ref.read(sessionsDataProvider).getById(sessionId);
    final externalId = row?.externalSessionId;
    if (row == null || externalId == null || externalId.isEmpty) {
      return const LastAnswer.missing(
        'This session has not started a conversation yet.',
      );
    }
    final agentId = _ref
        .read(agentInstallationsDataProvider)
        .getById(row.agentInstallationId)
        ?.agentId;
    if (agentId == null) {
      return const LastAnswer.missing(
        'Its agent is no longer installed, so its record cannot be found.',
      );
    }
    final path = await _ref
        .read(sessionTranscriptLocatorProvider)
        .locate(agentId: agentId, externalSessionId: externalId);
    if (path == null) {
      return const LastAnswer.missing(
        'Its conversation record was not found on this machine.',
      );
    }
    return LastAnswer.from(await readCliTranscriptOffThread(path, agentId));
  }

  /// [sessionId]'s plan and open calls, from one server read; null where the
  /// server does not read transcripts or refuses.
  Future<OverviewGlance?> glance(String sessionId) async {
    if (!_ref.read(capabilitiesProvider).chatViaServer) return null;
    try {
      final page = await _ref
          .read(serverTranscriptsProvider)
          .glance(sessionId)
          .timeout(kOverviewReadTimeout);
      return page.absence == null ? overviewGlanceOf(page) : OverviewGlance.empty;
    } on Object {
      return null;
    }
  }

  /// The files [sessionId] changed, from its own record or its checkpoints;
  /// null when neither can say.
  Future<List<String>?> changedFiles(String sessionId) async {
    try {
      final report = await _ref
          .read(sessionChangedFilesServiceProvider)
          .read(sessionId)
          .timeout(kOverviewReadTimeout);
      return switch (report.outcome) {
        SessionChangedFilesOutcome.fromAgentRecord ||
        SessionChangedFilesOutcome.fromCheckpoints ||
        SessionChangedFilesOutcome.agentRecordNamesNoFile ||
        SessionChangedFilesOutcome.checkpointsNameNoFile => [
          for (final file in report.files) file.path,
        ],
        _ => null,
      };
    } on Object {
      return null;
    }
  }
}

final overviewReaderProvider = Provider<OverviewReader>(OverviewReader.new);

/// The status word and its open asks, read again only when they change.
Object? _turnOf(Ref ref, String sessionId) => ref.watch(
  agentSessionStatusProvider(sessionId).select((r) {
    final report = r.asData?.value;
    return (report?.status, report?.inFlight.length, report?.backgroundOnly);
  }),
);

/// Session [String]'s last answer, read once and again when its turn moves.
final overviewLastAnswerProvider = FutureProvider.autoDispose
    .family<LastAnswer, String>((ref, sessionId) {
      _turnOf(ref, sessionId);
      return ref.read(overviewReaderProvider).lastAnswer(sessionId);
    });

/// Session [String]'s plan and open calls, read once and again when its turn
/// moves.
final overviewGlanceProvider = FutureProvider.autoDispose
    .family<OverviewGlance?, String>((ref, sessionId) {
      _turnOf(ref, sessionId);
      return ref.read(overviewReaderProvider).glance(sessionId);
    });

/// The files session [String] changed, read once and again when its turn
/// moves.
final overviewChangedFilesProvider = FutureProvider.autoDispose
    .family<List<String>?, String>((ref, sessionId) {
      _turnOf(ref, sessionId);
      return ref.read(overviewReaderProvider).changedFiles(sessionId);
    });

/// Lines added and removed per file in [EnvironmentPath] checkout, for the
/// peek's Files; empty when git cannot say.
final overviewFileStatsProvider = FutureProvider.autoDispose
    .family<Map<String, FileDiffStat>, EnvironmentPath>((ref, checkout) async {
      try {
        return await ref.read(gitDataProvider).fileDiffStats(checkout);
      } on Object {
        return const {};
      }
    });
