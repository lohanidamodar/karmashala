import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/transitions.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:test/test.dart';

const _policy = AgentNotificationPolicy();

NotificationDecision _decide(
  AgentActivityStatus to,
  NotifyLevel level, {
  bool focused = false,
  bool onlyWhenUnfocused = true,
  Set<String> visible = const {},
}) => _policy.decide(
  NotificationContext(
    transition: AgentStatusTransition(
      session: AgentSessionKey('claudeCode', 's1'),
      from: AgentActivityStatus.working,
      to: to,
      source: AgentStatusSource.hook,
    ),
    settings: NotificationSettings(
      level: level,
      onlyWhenUnfocused: onlyWhenUnfocused,
    ),
    windowFocused: focused,
    visibleSessionIds: visible,
  ),
);

void main() {
  group('the level table', () {
    test('Everything interrupts for every reason', () {
      for (final reason in NotificationReason.values) {
        expect(
          reason.interruptsAt(NotifyLevel.everything),
          isTrue,
          reason: reason.name,
        );
      }
    });

    test('Only when I am needed interrupts for what stops on you', () {
      final table = {
        for (final reason in NotificationReason.values)
          reason: reason.interruptsAt(NotifyLevel.whenNeeded),
      };
      expect(table, {
        NotificationReason.finished: false,
        NotificationReason.needsInput: true,
        NotificationReason.failed: true,
        NotificationReason.checksFailed: true,
        NotificationReason.changesRequested: true,
        NotificationReason.readyToMerge: false,
      });
    });

    test('Nothing interrupts for nothing', () {
      for (final reason in NotificationReason.values) {
        expect(
          reason.interruptsAt(NotifyLevel.nothing),
          isFalse,
          reason: reason.name,
        );
      }
    });

    test('the inbox kinds read the same table', () {
      final quiet = {
        for (final kind in InboxItemKind.values)
          if (kind.isQuiet) kind,
      };
      expect(quiet, {
        InboxItemKind.finished,
        InboxItemKind.readyToMerge,
        InboxItemKind.followUp,
        InboxItemKind.usageLimit,
        InboxItemKind.turnCutOff,
        InboxItemKind.automationProposed,
        InboxItemKind.wentQuiet,
        InboxItemKind.storeNews,
      });
      for (final reason in NotificationReason.values) {
        expect(
          InboxItemKind.of(reason).isQuiet,
          !reason.interruptsAt(NotifyLevel.whenNeeded),
          reason: reason.name,
        );
      }
    });
  });

  group('the old switches, read as a level', () {
    NotifyLevel read(Map<String, dynamic> json) =>
        NotificationSettings.fromJson(json).level;

    test('none recorded is Everything', () {
      expect(read(const {}), NotifyLevel.everything);
    });

    test('both on is Everything', () {
      expect(
        read(const {
          'enabled': true,
          'notifyWhenFinished': true,
          'notifyWhenAttentionNeeded': true,
        }),
        NotifyLevel.everything,
      );
    });

    test('finished off with attention on is Only when needed', () {
      expect(
        read(const {
          'enabled': true,
          'notifyWhenFinished': false,
          'notifyWhenAttentionNeeded': true,
        }),
        NotifyLevel.whenNeeded,
      );
    });

    test('both off is Nothing', () {
      expect(
        read(const {
          'enabled': true,
          'notifyWhenFinished': false,
          'notifyWhenAttentionNeeded': false,
        }),
        NotifyLevel.nothing,
      );
    });

    test('the master switch off is Nothing, whatever else it says', () {
      expect(
        read(const {
          'enabled': false,
          'notifyWhenFinished': true,
          'notifyWhenAttentionNeeded': true,
        }),
        NotifyLevel.nothing,
      );
    });

    test('finished on with attention off stays Everything', () {
      expect(
        read(const {
          'notifyWhenFinished': true,
          'notifyWhenAttentionNeeded': false,
        }),
        NotifyLevel.everything,
      );
    });

    test('a recorded level wins over the old switches', () {
      expect(
        read(const {'level': 'whenNeeded', 'enabled': false}),
        NotifyLevel.whenNeeded,
      );
    });

    test('an unknown level falls back to the old switches', () {
      expect(
        read(const {'level': 'loud', 'enabled': false}),
        NotifyLevel.nothing,
      );
    });
  });

  group('written for an older app too', () {
    test('every level round-trips', () {
      for (final level in NotifyLevel.values) {
        final settings = NotificationSettings(
          level: level,
          onlyWhenUnfocused: false,
        );
        expect(NotificationSettings.fromJson(settings.toJson()), settings);
      }
    });

    test('each level writes the switches an older app reads', () {
      Map<String, Object?> old(NotifyLevel level) {
        final json = NotificationSettings(level: level).toJson();
        return {
          'enabled': json['enabled'],
          'notifyWhenFinished': json['notifyWhenFinished'],
          'notifyWhenAttentionNeeded': json['notifyWhenAttentionNeeded'],
        };
      }

      expect(old(NotifyLevel.everything), {
        'enabled': true,
        'notifyWhenFinished': true,
        'notifyWhenAttentionNeeded': true,
      });
      expect(old(NotifyLevel.whenNeeded), {
        'enabled': true,
        'notifyWhenFinished': false,
        'notifyWhenAttentionNeeded': true,
      });
      expect(old(NotifyLevel.nothing)['enabled'], isFalse);
    });

    test('what an older app writes back keeps its meaning', () {
      // An older app rewrites only its four keys, dropping `level`.
      final json = NotificationSettings(level: NotifyLevel.whenNeeded).toJson()
        ..remove('level');
      expect(NotificationSettings.fromJson(json).level, NotifyLevel.whenNeeded);
    });
  });

  group('the desktop toast at each level', () {
    test('Everything toasts a finished turn and an ask', () {
      expect(
        _decide(AgentActivityStatus.idle, NotifyLevel.everything).reason,
        NotificationReason.finished,
      );
      expect(
        _decide(
          AgentActivityStatus.awaitingApproval,
          NotifyLevel.everything,
        ).reason,
        NotificationReason.needsInput,
      );
    });

    test('Only when needed logs a finished turn quietly', () {
      final finished = _decide(
        AgentActivityStatus.idle,
        NotifyLevel.whenNeeded,
      );
      expect(finished.shouldNotify, isFalse);
      expect(finished.suppression, NotificationSuppression.loggedQuietly);
      expect(finished.quietReason, NotificationReason.finished);
    });

    test('Only when needed still toasts an ask and a failure', () {
      expect(
        _decide(
          AgentActivityStatus.awaitingApproval,
          NotifyLevel.whenNeeded,
        ).reason,
        NotificationReason.needsInput,
      );
      expect(
        _decide(AgentActivityStatus.failed, NotifyLevel.whenNeeded).reason,
        NotificationReason.failed,
      );
    });

    test('Nothing toasts nothing, and logs nothing quietly to show', () {
      for (final status in [
        AgentActivityStatus.idle,
        AgentActivityStatus.awaitingApproval,
        AgentActivityStatus.failed,
      ]) {
        final decision = _decide(status, NotifyLevel.nothing);
        expect(decision.shouldNotify, isFalse, reason: '$status');
        expect(decision.quietReason, isNull, reason: '$status');
        expect(
          decision.suppression,
          NotificationSuppression.notificationsDisabled,
        );
      }
    });

    test('a quiet item for the session on screen is not even quiet', () {
      final decision = _decide(
        AgentActivityStatus.idle,
        NotifyLevel.whenNeeded,
        focused: true,
        visible: const {'s1'},
      );
      expect(decision.suppression, NotificationSuppression.sessionOnScreen);
      expect(decision.quietReason, isNull);
    });

    test('"only while unfocused" still holds for what does interrupt', () {
      expect(
        _decide(
          AgentActivityStatus.failed,
          NotifyLevel.whenNeeded,
          focused: true,
        ).suppression,
        NotificationSuppression.windowFocused,
      );
    });
  });
}
