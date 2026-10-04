import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefusalCode, DataRefused;
import 'package:karmashala_session/events.dart';
import 'package:karmashala_terminal_runtime/instances.dart'
    show HostTerminalInstance;
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../agents/application/agent_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../data/server_transcripts.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'ask_resolutions.dart';
import 'decision_recorder.dart';
import 'host_lifecycle/host_agent_statuses.dart';
import 'host_lifecycle/host_lifecycle_providers.dart';
import 'session_chat_source.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';
import 'dart:async';

/// **Every prompt answer the app gives, and where it is typed.** A session
/// this machine's session host runs is answered by the host — it holds the
/// PTY and the status, and answers the same way with the app closed; a pane
/// no host holds (the in-app PTY path, e.g. Windows) is answered here, by the
/// same [SessionPromptAnswers] over this app's panes. The phone's bindings,
/// the desktop card and `session_answer` all come through here.
class AppPromptAnswers implements PromptAnswering {
  AppPromptAnswers({
    required this.local,
    required this.hostAnswers,
    required this.hostChecksAsk,
    this.onAnswering,
  });

  /// This app's own panes.
  final SessionPromptAnswers local;

  /// The host's answer for a session it runs, or null for one it does not.
  final Future<SessionApprovalAnswer> Function(PromptAnswerRequest request)?
  Function(String sessionId)
  hostAnswers;

  /// Whether the host refuses an approval whose prompt has gone
  /// (`Capabilities.answersCarryAsk`). This app's own panes always do.
  final bool Function() hostChecksAsk;

  /// Told of every answer before it is sent, so a prompt this client closed
  /// is never said to have been answered elsewhere.
  final void Function(String sessionId)? onAnswering;

  @override
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) async {
    onAnswering?.call(request.sessionId);
    final host = hostAnswers(request.sessionId);
    if (host == null) return local.answer(request);
    final checked = hostChecksAsk();
    try {
      // An older host is sent what it has always read.
      return await host(
        request is ApprovalAnswerRequest && !checked
            ? request.withoutAsk()
            : request,
      );
    } on SessionPromptRefusal catch (refusal) {
      if (!refusal.unconfirmed || checked) rethrow;
      throw SessionPromptRefusal(
        '${refusal.message}. This server does not check which prompt an '
        'answer was for, so a late one can still land',
        unconfirmed: true,
      );
    }
  }

  /// Read here for either: the status is the host's for a session it holds
  /// (the registry renders it), the question travels in that status, and a
  /// menu is read off the pane that mirrors the host's screen.
  @override
  Future<PromptEvidence> evidence(String sessionId) =>
      local.evidence(sessionId);

  @override
  AgentScreenMenu? menuOnScreen(String sessionId) =>
      local.menuOnScreen(sessionId);
}

/// How often a surface showing a menu reads the screen again: one menu can
/// follow another (folder trust, then external imports) with no status change.
const Duration kMenuRereadInterval = Duration(milliseconds: 700);

/// The bottom rows of [String] session's live pane, as a menu is read, or null
/// without one.
final promptPaneScreenProvider =
    Provider<List<String>? Function(String sessionId)>((ref) {
      return (sessionId) {
        final paneId = ref.read(sessionLauncherProvider).livePaneFor(sessionId);
        if (paneId == null) return null;
        final instance = ref
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(paneId);
        if (instance == null) return null;
        return terminalTailLines(instance.terminal, lines: kMenuScreenRows);
      };
    });

/// Whether [String] session's menu, as this client reads it, is drawn at the
/// grid its answerer reads: a pane of this app's own, or a hosted pane on
/// this machine's server that the session is sized for. A menu's id hashes
/// its rows, and a pane at another grid wraps them differently — so only
/// then may an approval name the menu it was drawn from.
final promptMenuAtSessionGridProvider = Provider<bool Function(String)>(
  (ref) => (sessionId) {
    if (!ref.read(capabilitiesProvider).readsServerDisk) return false;
    final paneId = ref.read(sessionLauncherProvider).livePaneFor(sessionId);
    if (paneId == null) return false;
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null) return false;
    if (instance is! HostTerminalInstance) return true;
    final presence = instance.presence.value;
    return presence != null && presence.sizedFor == presence.me;
  },
);

/// Presses keys into [String] session's live pane, recording nothing; false
/// without one.
final promptPanePressProvider =
    Provider<bool Function(String sessionId, String keys)>(
      (ref) =>
          (sessionId, keys) =>
              ref.read(sessionLauncherProvider).pressKeys(sessionId, keys),
    );

/// The question [String] session's agent has open in its own transcript, or
/// null — for a pane no host holds. Read from the file the status registry
/// reads, so it is the question the status was about.
final transcriptOpenQuestionProvider =
    Provider<
      Future<AgentQuestionSet?> Function(String sessionId, String agentId)
    >((ref) {
      return (sessionId, agentId) async {
        final support = ref
            .read(agentRegistryProvider)
            .byId(agentId)
            ?.questions;
        if (support == null) return null;
        // Read where the record is when the server offers it: the registry's
        // path is spelled for the server's disk. An older server refuses the
        // kind `invalid`, and this disk is read as before.
        if (ref.read(capabilitiesProvider).openQuestionViaServer) {
          try {
            return await ref
                .read(serverTranscriptsProvider)
                .openQuestion(sessionId);
          } on DataRefused catch (refusal) {
            if (refusal.code != DataRefusalCode.invalid) return null;
          }
        }
        // The registry's path when it has one — the file the status came
        // from. It resolves one only for a session it has to probe, and one
        // fresh from a hook or the screen is not, so the store is asked too.
        var path = ref
            .read(sessionStatusRegistryProvider)
            .transcriptPathForOpenId(sessionId);
        if (path == null) {
          final external = ref
              .read(sessionsDataProvider)
              .getById(sessionId)
              ?.externalSessionId;
          if (external == null || external.isEmpty) return null;
          path = await ref
              .read(sessionTranscriptLocatorProvider)
              .locate(agentId: agentId, externalSessionId: external);
        }
        if (path == null) return null;
        try {
          return openQuestionIn(await _tail(File(path)), support);
        } on FileSystemException {
          return null;
        }
      };
    });

/// The end of a transcript: a question is the newest thing in it while open.
Future<String> _tail(File file, {int bytes = 65536}) async {
  final handle = await file.open();
  try {
    final size = await handle.length();
    final start = size > bytes ? size - bytes : 0;
    await handle.setPosition(start);
    return const Utf8Decoder(
      allowMalformed: true,
    ).convert(await handle.read(size - start));
  } finally {
    await handle.close();
  }
}

/// This app's panes, as [SessionPromptAnswers] reaches them.
class AppPromptTerminals implements PromptTerminals {
  AppPromptTerminals(this._ref);

  final Ref _ref;

  @override
  bool exists(String sessionId) =>
      _ref.read(sessionsDataProvider).getById(sessionId) != null;

  @override
  AgentDescriptor? agentOf(String sessionId) {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return null;
    final agentId = _ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    return agentId == null
        ? null
        : _ref.read(agentRegistryProvider).byId(agentId);
  }

  @override
  AgentStatusReport? statusOf(String sessionId) =>
      _ref.read(sessionStatusLookupProvider)(sessionId);

  /// The host's question for a session it holds — it read it off the hook
  /// that opened it — else this app's reading of the agent's transcript.
  @override
  Future<AgentQuestionSet?> openQuestion(String sessionId) async {
    // The host keeps one only while its hook or the agent's protocol is the
    // status's word; without that, the record is read as for any pane. A chat
    // session has no record to read it from.
    final hosted = _ref.read(hostAgentStatusesProvider).of(sessionId);
    if (hosted?.question case final question?) return question;
    final agentId = agentOf(sessionId)?.id;
    if (agentId == null) return null;
    return _ref.read(transcriptOpenQuestionProvider)(sessionId, agentId);
  }

  @override
  List<String>? screen(String sessionId) =>
      _ref.read(promptPaneScreenProvider)(sessionId);

  @override
  bool press(String sessionId, String keys) =>
      _ref.read(promptPanePressProvider)(sessionId, keys);

  @override
  void record(DecisionRecord decision) =>
      unawaited(_ref.read(decisionRecorderProvider).file(decision));
}

/// Answers over this app's own panes — the path for a pane no host holds.
final localPromptAnswersProvider = Provider<SessionPromptAnswers>(
  (ref) => SessionPromptAnswers(terminals: AppPromptTerminals(ref)),
);

/// Every prompt answer the app gives: the host's for a session it runs, this
/// app's panes' otherwise.
final sessionPromptAnswersProvider = Provider<PromptAnswering>(
  (ref) => AppPromptAnswers(
    local: ref.watch(localPromptAnswersProvider),
    hostAnswers: (sessionId) {
      final subscriber = ref.read(hostLifecycleSubscriberProvider);
      if (subscriber == null || !subscriber.isRunning(sessionId)) return null;
      return subscriber.answerPrompt;
    },
    hostChecksAsk: () => ref.read(capabilitiesProvider).answersCarryAsk,
    onAnswering: ref.read(ownPromptAnswersProvider).note,
  ),
);

/// Whether [String] session can be answered from the app at all: a live pane
/// of its own, or a process this machine's host runs — and, on a phone, a
/// pairing that grants `approve`.
final sessionAnswerableProvider = Provider<bool Function(String sessionId)>(
  (ref) =>
      (sessionId) =>
          ref.read(capabilitiesProvider).mayApprove &&
          (ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null ||
              (ref
                      .read(hostLifecycleSubscriberProvider)
                      ?.isRunning(sessionId) ??
                  false)),
);
