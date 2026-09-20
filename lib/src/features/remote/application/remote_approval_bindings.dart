/// The approval path, both halves: one rule — a key may be offered, and
/// pressed, only for a wait a status source identified as an approval.
library;

import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../sessions/application/session_key_pacer.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_menu_answerer.dart';
import '../../sessions/application/session_question_typist.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';

/// The evidence lookup, stubbed in tests because the real one reads
/// `agentSessionStatusProvider` — a terminal grid and the CLI store on disk.
final remoteApprovalEvidenceProvider =
    Provider<Future<AgentStatusReport?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          return await ref.read(agentSessionStatusProvider(sessionId).future);
        } on Object {
          return null;
        }
      };
    });

/// The answer path: the key comes from [AgentApprovalRules] and is pressed by
/// [SessionLauncher.answerPrompt] — nothing here invents a binding.
Future<String> answerRemoteApproval(
  Ref ref,
  String sessionId,
  String decision,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final rules = agentId == null
      ? const AgentApprovalRules()
      : ref.read(agentRegistryProvider).byId(agentId)?.approval ??
            const AgentApprovalRules();
  final key = decision == 'approve' ? rules.approve : rules.deny;
  if (key == null) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      'this agent names no way to $decision from outside its terminal',
    );
  }
  // Enforced where the key is pressed: a phone holding a stale card must not
  // type Enter into a session that has merely finished its turn.
  if (!_hasOpenPrompt(
    await ref.read(remoteApprovalEvidenceProvider)(sessionId),
  )) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this session has no prompt open to answer',
    );
  }
  if (!ref.read(sessionLauncherProvider).answerPrompt(sessionId, key.keys)) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this session has no live terminal to answer in',
    );
  }
  return key.label;
}

/// The question [sessionId]'s agent has open in its transcript right now, or
/// null. Read from the file the status registry reads, so it is the question
/// the status was about; stubbed in tests.
final remoteOpenQuestionProvider =
    Provider<
      Future<AgentQuestionSet?> Function(String sessionId, String agentId)
    >((ref) {
      return (sessionId, agentId) async {
        final support = ref
            .read(agentRegistryProvider)
            .byId(agentId)
            ?.questions;
        if (support == null) return null;
        // The registry's path when it has one — the file the status came
        // from. It resolves one only for a session it has to probe, and one
        // fresh from a hook or the screen is not, so the store is asked too.
        var path = ref
            .read(sessionStatusRegistryProvider)
            .transcriptPathForOpenId(sessionId);
        if (path == null) {
          final external = ref
              .read(sessionDaoProvider)
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

/// Answers — or declines — an agent's open question with the keys its
/// [AgentQuestionSupport] measured. Refused, and nothing typed, unless the
/// session still shows a question **and** the one open in its transcript is
/// the one the phone was answering.
Future<String> answerRemoteQuestion(
  Ref ref,
  RemoteQuestionAnswerRequest request,
) async {
  final sessionId = request.sessionId;
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final support = agentId == null
      ? null
      : ref.read(agentRegistryProvider).byId(agentId)?.questions;
  if (agentId == null || support == null) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      "this agent's questions can only be answered in its terminal",
    );
  }
  final report = await ref.read(remoteApprovalEvidenceProvider)(sessionId);
  if (!(report?.hasOpenQuestion ?? false)) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this session has no question open to answer',
    );
  }
  final open = await ref.read(remoteOpenQuestionProvider)(sessionId, agentId);
  if (open == null || open.toolUseId != request.toolUseId) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this question has already been answered',
    );
  }
  if (request.decline) {
    if (!await ref
        .read(sessionKeyPacerProvider)
        .type(sessionId, support.declineKeys)) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'this session has no live terminal to answer in',
      );
    }
    return 'declined';
  }
  final answers = [
    for (final answer in request.answers)
      answer.text != null
          ? AgentQuestionAnswer.text(answer.text!)
          : AgentQuestionAnswer.options(answer.options),
  ];
  try {
    // The measured keys double as the check that the answer fits at all,
    // before a single key is pressed.
    support.keysFor(open, answers);
  } on ArgumentError catch (error) {
    throw RemoteApiRefusal(ErrorCode.badRequest, '${error.message}');
  }
  try {
    await ref
        .read(sessionQuestionTypistProvider)
        .answer(sessionId, open, answers);
  } on SessionPromptRefusal catch (refusal) {
    throw RemoteApiRefusal(ErrorCode.badRequest, refusal.message);
  }
  return 'answered';
}

Future<RemoteApprovalRequest> remoteApprovalEvidenceFor(
  Ref ref,
  String sessionId,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  final agentId = session == null
      ? null
      : ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId)
            ?.agentId;
  final rules = agentId == null
      ? null
      : ref.read(agentRegistryProvider).byId(agentId)?.approval;
  final report = await ref.read(remoteApprovalEvidenceProvider)(sessionId);
  final asking = report?.status == AgentActivityStatus.awaitingApproval;
  final answerable = _hasOpenPrompt(report);
  // A question travels whole, and never with approve/deny beside it.
  final question = report?.hasOpenQuestion == true && agentId != null
      ? await ref.read(remoteOpenQuestionProvider)(sessionId, agentId)
      : null;
  // A menu read off the pane is answered by option, and travels without
  // approve/deny: Enter chooses whatever is highlighted, which on a
  // folder-trust prompt is "No, exit" — and an older phone that cannot read
  // the menu then says to answer at the desk rather than offer that Enter.
  final menu = answerable
      ? ref.read(sessionMenuAnswererProvider).read(sessionId)
      : null;
  return RemoteApprovalRequest(
    question: question == null ? null : _wireQuestion(question),
    menu: menu == null ? null : remoteMenuOf(menu),
    sessionId: sessionId,
    evidence: asking ? report!.evidence : const [],
    waiting: asking ? _wireWait(report!.waiting) : RemoteWaitKind.unrecorded,
    // Keys only for a prompt a source could see: `awaitingApproval` is also
    // true of an agent at its own input, where approve would type Enter.
    approveLabel: answerable && menu == null ? rules?.approve?.label : null,
    denyLabel: answerable && menu == null ? rules?.deny?.label : null,
  );
}

/// Chooses the option [request] names of the menu on the session's screen,
/// through the same answerer the chat view uses. Refused, with nothing chosen,
/// unless the session still shows a prompt and it is the menu the phone saw.
Future<String> answerRemoteMenu(
  Ref ref,
  RemoteMenuAnswerRequest request,
) async {
  final sessionId = request.sessionId;
  if (ref.read(sessionDaoProvider).getById(sessionId) == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  if (!_hasOpenPrompt(
    await ref.read(remoteApprovalEvidenceProvider)(sessionId),
  )) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'this session has no prompt open to answer',
    );
  }
  try {
    return await ref
        .read(sessionMenuAnswererProvider)
        .choose(sessionId, menuId: request.menuId, option: request.option);
  } on SessionPromptRefusal catch (refusal) {
    throw RemoteApiRefusal(ErrorCode.badRequest, refusal.message);
  }
}

/// The question open in [sessionId], shaped exactly as the phone receives it —
/// for the desktop chat view, which answers it with the same card and through
/// the same guarded path. Null while no question is open or it cannot be read.
final chatOpenQuestionProvider = FutureProvider.autoDispose
    .family<RemoteQuestion?, String>((ref, sessionId) async {
      final report = ref
          .watch(agentSessionStatusProvider(sessionId))
          .asData
          ?.value;
      if (report == null || !report.hasOpenQuestion) return null;
      final open = await ref.read(remoteOpenQuestionProvider)(
        sessionId,
        report.agentId,
      );
      return open == null ? null : _wireQuestion(open);
    });

/// Answers a question from the desktop chat view through [answerRemoteQuestion]
/// — the same checks the phone's answer passes, and the same keys.
final chatQuestionAnswerProvider =
    Provider<Future<String> Function(RemoteQuestionAnswerRequest request)>(
      (ref) =>
          (request) => answerRemoteQuestion(ref, request),
    );

/// A menu read off the screen, as the wire and the shared card carry it.
RemoteMenu remoteMenuOf(AgentScreenMenu menu) => RemoteMenu(
  menuId: menu.id,
  prompt: menu.prompt,
  options: menu.options,
  highlighted: menu.highlighted,
);

/// The one rule both halves turn on, kept on [AgentStatusReport.hasOpenPrompt]
/// because `session_send` refuses on it too. Absent is not an open prompt.
bool _hasOpenPrompt(AgentStatusReport? report) =>
    report?.hasOpenPrompt ?? false;

RemoteWaitKind _wireWait(AgentWaitKind kind) => switch (kind) {
  AgentWaitKind.approval => RemoteWaitKind.approval,
  AgentWaitKind.input => RemoteWaitKind.input,
  AgentWaitKind.unrecorded => RemoteWaitKind.unrecorded,
  AgentWaitKind.question => RemoteWaitKind.question,
};

RemoteQuestion _wireQuestion(AgentQuestionSet set) => RemoteQuestion(
  toolUseId: set.toolUseId,
  questions: [
    for (final q in set.questions)
      RemoteQuestionItem(
        question: q.question,
        header: q.header,
        multiSelect: q.multiSelect,
        options: [
          for (final o in q.options)
            RemoteQuestionOption(label: o.label, description: o.description),
        ],
      ),
  ],
);
