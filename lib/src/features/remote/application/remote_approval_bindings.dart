/// The approval path, both halves: one rule — a key may be offered, and
/// pressed, only for a wait a status source identified as an approval — kept
/// in `karmashala_agent_status` and shaped for the wire by [CompanionPrompts].
/// A session this machine's host runs is answered by the host.
library;

import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show CompanionPrompts, remoteQuestionOf;
import 'package:karmashala_remote/remote.dart';
import 'package:riverpod/riverpod.dart';

import '../../sessions/application/session_prompt_answers.dart';
import '../../sessions/application/session_status_providers.dart';

/// A phone's approval, question and menu calls — and the desktop chat view's,
/// which answers with the same cards through the same guards.
final remotePromptsProvider = Provider<CompanionPrompts>(
  (ref) => CompanionPrompts(ref.watch(sessionPromptAnswersProvider)),
);

/// The question open in [String] session, shaped exactly as the phone
/// receives it — for the desktop chat view. Null while no question is open or
/// it cannot be read.
final chatOpenQuestionProvider = FutureProvider.autoDispose
    .family<RemoteQuestion?, String>((ref, sessionId) async {
      final report = ref
          .watch(agentSessionStatusProvider(sessionId))
          .asData
          ?.value;
      if (report == null || !report.hasOpenQuestion) return null;
      final open = await AppPromptTerminals(ref).openQuestion(sessionId);
      return open == null ? null : remoteQuestionOf(open);
    });

/// Answers a question from the desktop chat view exactly as the phone's
/// answer is: the same checks, the same keys, the same place they are typed.
final chatQuestionAnswerProvider =
    Provider<Future<String> Function(RemoteQuestionAnswerRequest request)>(
      (ref) =>
          (request) => ref.read(remotePromptsProvider).answerQuestion(request),
    );
