import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_core/util.dart';
import 'package:karmashala_session/events.dart' show DecisionOrigin;
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../notifications/application/notification_providers.dart'
    show windowFocusedProvider;
import 'host_lifecycle/host_lifecycle_providers.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';

/// How long a phone says "Answered elsewhere" where the ask was (Stage 3
/// step 4).
const Duration kAnsweredElsewhereShown = Duration(seconds: 4);

/// How long a closed ask is left before it is judged: a session that ended
/// can report the ending just after the status that closed the ask.
const Duration kAskClosingSettle = Duration(milliseconds: 500);

/// When this client last sent something that can close a session's prompt:
/// an answer through the one answer path, or an interrupt.
class OwnPromptAnswers {
  OwnPromptAnswers(this._clock);

  final Clock _clock;
  final _sentAt = <String, DateTime>{};

  void note(String sessionId) => _sentAt[sessionId] = _clock.nowUtc();

  bool sentSince(String sessionId, DateTime since) {
    final at = _sentAt[sessionId];
    return at != null && !at.isBefore(since);
  }
}

final ownPromptAnswersProvider = Provider<OwnPromptAnswers>(
  (ref) => OwnPromptAnswers(ref.read(clockProvider)),
);

/// What to say where [String] session's ask was, once it has closed: "Answered
/// elsewhere", naming who when the decision record does — or null to say
/// nothing. Nothing when this client answered it since [shownAt], when this
/// client's terminal for the session is on screen (a key typed there closes
/// it too), when the session ended, and when the status cannot tell.
/// [waitingSince] is the closed ask's, as its status gave it.
final askAnsweredElsewhereProvider =
    Provider<
      String? Function(
        String sessionId, {
        required DateTime shownAt,
        DateTime? waitingSince,
      })
    >((ref) {
      return (sessionId, {required shownAt, waitingSince}) {
        if (ref.read(ownPromptAnswersProvider).sentSince(sessionId, shownAt)) {
          return null;
        }
        final now = ref.read(sessionStatusLookupProvider)(sessionId);
        if (now == null) return null;
        switch (now.status) {
          case AgentActivityStatus.failed || AgentActivityStatus.unknown:
            return null;
          case AgentActivityStatus.awaitingApproval
              when waitingSince == null ||
                  now.waitingSince?.millisecondsSinceEpoch ==
                      waitingSince.millisecondsSinceEpoch:
            // Still waiting, or cannot tell that it is a new wait: an ask
            // dismissed from the Inbox was not answered.
            return null;
          default:
            break;
        }
        final sessions = ref.read(sessionsDataProvider);
        final session = sessions.getById(sessionId);
        if (session == null || session.status.isEnded) return null;
        final host = ref.read(hostLifecycleSubscriberProvider);
        if (host != null &&
            host.knows(sessionId) &&
            !host.isRunning(sessionId)) {
          return null;
        }
        final paneId = session.paneId;
        if (paneId != null &&
            ref.read(windowFocusedProvider) &&
            ref.read(foregroundTerminalPaneIdsProvider).contains(paneId)) {
          return null;
        }
        final by = _decidedBy(ref, sessionId, waitingSince);
        return by == null ? 'Answered elsewhere' : 'Answered elsewhere, by $by';
      };
    });

/// Who the decision record says answered the ask that began at
/// [waitingSince], when it names someone other than "the user" — an agent,
/// in the words a person reads. The record never names a device.
String? _decidedBy(Ref ref, String sessionId, DateTime? waitingSince) {
  if (waitingSince == null) return null;
  final decisions = ref.read(sessionRecordsProvider).decisionsFor(sessionId);
  for (final decision in decisions.reversed) {
    if (decision.origin != DecisionOrigin.approvalPrompt) continue;
    if (decision.recordedAt.isBefore(waitingSince)) return null;
    final by = decision.decidedBy;
    if (by == null || by == 'the user') return null;
    final agentSession = decision.recordedBySessionId;
    final title = agentSession == null
        ? null
        : ref.read(sessionsDataProvider).getById(agentSession)?.title;
    return title == null || title.isEmpty ? by : 'an agent in “$title”';
  }
  return null;
}
