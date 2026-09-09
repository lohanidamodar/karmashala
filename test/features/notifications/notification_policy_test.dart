import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/agent_status_transition.dart';
import 'package:karmashala/src/features/notifications/domain/notification_policy.dart';
import 'package:karmashala/src/features/notifications/domain/notification_settings.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:flutter_test/flutter_test.dart';

const _policy = AgentNotificationPolicy();

/// Builds a decision context. Defaults describe the ordinary case this feature
/// exists for: the app is in the background and the user is somewhere else.
NotificationContext _context({
  AgentActivityStatus? from,
  required AgentActivityStatus to,
  AgentStatusSource source = AgentStatusSource.hook,
  NotificationSettings settings = const NotificationSettings(),
  bool focused = false,
  Set<String> visible = const {},
  String sessionId = 's1',
}) => NotificationContext(
  transition: AgentStatusTransition(
    session: AgentSessionKey('claudeCode', sessionId),
    from: from,
    to: to,
    source: source,
  ),
  settings: settings,
  windowFocused: focused,
  visibleSessionIds: visible,
);

NotificationReason? _reason(NotificationContext context) =>
    _policy.decide(context).reason;

NotificationSuppression? _suppression(NotificationContext context) =>
    _policy.decide(context).suppression;

void main() {
  group('what is worth interrupting for', () {
    test('an agent that finished its turn', () {
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.idle,
          ),
        ),
        NotificationReason.finished,
      );
    });

    test('an agent waiting for approval', () {
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.awaitingApproval,
          ),
        ),
        NotificationReason.needsInput,
      );
    });

    test('an agent that failed', () {
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.failed,
          ),
        ),
        NotificationReason.failed,
      );
    });

    test('an agent picking work up is not news', () {
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.idle,
            to: AgentActivityStatus.working,
          ),
        ),
        NotificationSuppression.notWorthInterrupting,
      );
    });

    test('losing track of a session is not news', () {
      // A hook going stale, or the CLI exiting mid-turn. Neither is something
      // the user did or needs to answer.
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.unknown,
          ),
        ),
        NotificationSuppression.lostTrack,
      );
    });

    test('a status that did not move is not a transition', () {
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.awaitingApproval,
            to: AgentActivityStatus.awaitingApproval,
          ),
        ),
        NotificationSuppression.notAChange,
      );
    });

    test('the whole rule, as a table over every pair', () {
      // Pins the shape of the policy: with a hook reporting and the window in
      // the background, exactly these transitions interrupt.
      final notifying = <String>{};
      for (final from in AgentActivityStatus.values) {
        for (final to in AgentActivityStatus.values) {
          final decision = _policy.decide(_context(from: from, to: to));
          if (decision.shouldNotify) {
            notifying.add('${from.name}->${to.name}=${decision.reason!.name}');
          }
        }
      }
      expect(notifying, {
        'working->idle=finished',
        'awaitingApproval->idle=finished',
        'failed->idle=finished',
        'unknown->idle=finished',
        'idle->awaitingApproval=needsInput',
        'working->awaitingApproval=needsInput',
        'failed->awaitingApproval=needsInput',
        'unknown->awaitingApproval=needsInput',
        'idle->failed=failed',
        'working->failed=failed',
        'awaitingApproval->failed=failed',
        'unknown->failed=failed',
      });
    });
  });

  group('evidence that the change happened now', () {
    test('a state file with no previous status stays quiet', () {
      // Every live session is observed for the first time on app start. The
      // file may have looked like this for hours; a burst of toasts at launch
      // is exactly the behaviour that gets notifications switched off.
      expect(
        _suppression(
          _context(
            from: null,
            to: AgentActivityStatus.idle,
            source: AgentStatusSource.stateFile,
          ),
        ),
        NotificationSuppression.noEvidenceOfChange,
      );
    });

    test('a state file moving out of unknown stays quiet', () {
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.unknown,
            to: AgentActivityStatus.idle,
            source: AgentStatusSource.stateFile,
          ),
        ),
        NotificationSuppression.noEvidenceOfChange,
      );
    });

    test('a state file moving between two known statuses does notify', () {
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.idle,
            source: AgentStatusSource.stateFile,
          ),
        ),
        NotificationReason.finished,
      );
    });

    test('a hook is always first-hand evidence, even with no history', () {
      // The agent called us as it happened, so "we have never seen this
      // session" does not make the event any less real.
      expect(
        _reason(
          _context(
            from: null,
            to: AgentActivityStatus.awaitingApproval,
            source: AgentStatusSource.hook,
          ),
        ),
        NotificationReason.needsInput,
      );
    });
  });

  group('focus and what is on screen', () {
    const alwaysNotify = NotificationSettings(onlyWhenUnfocused: false);

    test('never for the session the user is looking at', () {
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.awaitingApproval,
            settings: alwaysNotify,
            focused: true,
            visible: const {'s1'},
          ),
        ),
        NotificationSuppression.sessionOnScreen,
      );
    });

    test('a selected session behind another app is not being looked at', () {
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.awaitingApproval,
            settings: alwaysNotify,
            focused: false,
            visible: const {'s1'},
          ),
        ),
        NotificationReason.needsInput,
      );
    });

    test('another session while focused still notifies when allowed', () {
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.idle,
            settings: alwaysNotify,
            focused: true,
            visible: const {'other'},
          ),
        ),
        NotificationReason.finished,
      );
    });

    test('by default a focused window is never interrupted', () {
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.idle,
            focused: true,
          ),
        ),
        NotificationSuppression.windowFocused,
      );
    });
  });

  group('settings', () {
    test('the master switch silences everything', () {
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.failed,
            settings: const NotificationSettings(enabled: false),
          ),
        ),
        NotificationSuppression.notificationsDisabled,
      );
    });

    test('muting "finished" leaves "needs you" alone', () {
      const settings = NotificationSettings(notifyWhenFinished: false);
      expect(
        _suppression(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.idle,
            settings: settings,
          ),
        ),
        NotificationSuppression.reasonMuted,
      );
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.awaitingApproval,
            settings: settings,
          ),
        ),
        NotificationReason.needsInput,
      );
    });

    test('muting "needs you" covers approvals and failures alike', () {
      const settings = NotificationSettings(notifyWhenAttentionNeeded: false);
      for (final status in [
        AgentActivityStatus.awaitingApproval,
        AgentActivityStatus.failed,
      ]) {
        expect(
          _suppression(
            _context(
              from: AgentActivityStatus.working,
              to: status,
              settings: settings,
            ),
          ),
          NotificationSuppression.reasonMuted,
          reason: '$status should be muted',
        );
      }
      expect(
        _reason(
          _context(
            from: AgentActivityStatus.working,
            to: AgentActivityStatus.idle,
            settings: settings,
          ),
        ),
        NotificationReason.finished,
      );
    });

    // The default field values themselves belong to notification_settings_test.
    // What each default *does* is already asserted above, through the policy:
    // 'an agent that finished its turn' and 'an agent waiting for approval'
    // cover enabled/notifyWhenFinished/notifyWhenAttentionNeeded, and 'by
    // default a focused window is never interrupted' covers onlyWhenUnfocused.
  });

  group('one table for agent status', () {
    // The tray's waiting list is a *level* and a toast is an *edge*: the
    // distinction is real and the two enums stay separate. What must not
    // happen is two tables — before Loop 68 `agent_status_watcher` carried its
    // own status→AttentionKind switch, so moving an arm in the policy left the
    // tray listing something no toast would ever mention.
    test('attention is exactly the statuses that ask something of you', () {
      for (final status in AgentActivityStatus.values) {
        final reason = AgentNotificationPolicy.reasonForStatus(status);
        final asksSomething =
            reason == NotificationReason.needsInput ||
            reason == NotificationReason.failed;
        expect(
          AttentionKind.forStatus(status) != null,
          asksSomething,
          reason:
              'AttentionKind.forStatus disagrees with the policy on $status',
        );
      }
    });

    test('a finished turn is news, not a hold-up', () {
      expect(
        AgentNotificationPolicy.reasonForStatus(AgentActivityStatus.idle),
        NotificationReason.finished,
      );
      expect(AttentionKind.forStatus(AgentActivityStatus.idle), isNull);
    });

    test('the two statuses only a hook can observe are both held', () {
      expect(
        AttentionKind.forStatus(AgentActivityStatus.awaitingApproval),
        AttentionKind.needsInput,
      );
      expect(
        AttentionKind.forStatus(AgentActivityStatus.failed),
        AttentionKind.failed,
      );
    });
  });
}
