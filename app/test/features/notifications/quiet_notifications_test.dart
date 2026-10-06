import 'package:agent_cli/descriptors.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/notifications/application/attention_presenter.dart';
import 'package:karmashala/src/features/notifications/data/phone_notification_presenter.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AttentionNews;
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_notifications/watched.dart';

const _watched = WatchedSession(
  key: AgentSessionKey(AgentIds.claudeCode, 's1'),
  label: 'Fix the tests',
  openId: 's1',
  imported: false,
);

AttentionNews _news(NotificationReason reason, AgentActivityStatus to) =>
    AttentionNews(
      session: _watched,
      reason: reason,
      from: AgentActivityStatus.working,
      to: to,
      source: AgentStatusSource.hook,
    );

final _finished = _news(NotificationReason.finished, AgentActivityStatus.idle);
final _ask = _news(
  NotificationReason.needsInput,
  AgentActivityStatus.awaitingApproval,
);

void main() {
  group('what a phone does with news, at each level', () {
    late List<PendingNotification> loud;
    late List<PendingNotification> quiet;

    AttentionPresenter phoneAt(NotifyLevel level) {
      loud = [];
      quiet = [];
      return AttentionPresenter(
        news: const Stream.empty(),
        readSettings: () =>
            NotificationSettings(level: level, onlyWhenUnfocused: false),
        isWindowFocused: () => true,
        visibleSessionIds: () => const {},
        onNotify: loud.add,
        onQuiet: quiet.add,
      );
    }

    test('Everything interrupts for a finished turn', () {
      phoneAt(NotifyLevel.everything).present(_finished);
      expect(loud.single.reason, NotificationReason.finished);
      expect(loud.single.quiet, isFalse);
      expect(quiet, isEmpty);
    });

    test('Only when needed shows a finished turn quietly', () {
      phoneAt(NotifyLevel.whenNeeded).present(_finished);
      expect(loud, isEmpty);
      expect(quiet.single.reason, NotificationReason.finished);
      expect(quiet.single.quiet, isTrue);
    });

    test('Only when needed still interrupts for an ask', () {
      phoneAt(NotifyLevel.whenNeeded).present(_ask);
      expect(loud.single.reason, NotificationReason.needsInput);
      expect(quiet, isEmpty);
    });

    test('Nothing shows nothing at all', () {
      final presenter = phoneAt(NotifyLevel.nothing);
      presenter.present(_finished);
      presenter.present(_ask);
      expect(loud, isEmpty);
      expect(quiet, isEmpty);
    });

    test('a desktop, with nowhere quiet to put it, shows nothing', () {
      final shown = <PendingNotification>[];
      AttentionPresenter(
        news: const Stream.empty(),
        readSettings: () =>
            const NotificationSettings(level: NotifyLevel.whenNeeded),
        isWindowFocused: () => false,
        visibleSessionIds: () => const {},
        onNotify: shown.add,
      ).present(_finished);
      expect(shown, isEmpty);
    });
  });

  group('one request per window', () {
    const coalescer = NotificationCoalescer();

    test('is quiet only when everything in it is', () {
      final quietFinished = _finished.pending.quietly();
      expect(coalescer.summarize([quietFinished])!.quiet, isTrue);
      expect(
        coalescer.summarize([quietFinished, _ask.pending])!.quiet,
        isFalse,
      );
      expect(coalescer.summarize([_ask.pending])!.quiet, isFalse);
    });
  });

  group('the phone channel', () {
    test('a quiet request goes to Quiet updates: low, no sound, no buzz', () {
      final details = PhoneNotificationPresenter.detailsFor(
        const NotificationRequest(
          title: 'Agent finished',
          body: 'x',
          quiet: true,
        ),
      );
      final android = details.android!;
      expect(android.channelId, PhoneNotificationPresenter.quietChannelId);
      expect(android.channelName, 'Quiet updates');
      expect(android.importance, Importance.low);
      expect(android.priority, Priority.low);
      expect(android.playSound, isFalse);
      expect(android.enableVibration, isFalse);
      final ios = details.iOS!;
      expect(ios.interruptionLevel, InterruptionLevel.passive);
      expect(ios.presentSound, isFalse);
    });

    test('anything else keeps the attention channel', () {
      final details = PhoneNotificationPresenter.detailsFor(
        const NotificationRequest(title: 'Agent needs you', body: 'x'),
      );
      expect(details.android!.channelId, PhoneNotificationPresenter.channelId);
      expect(details.android!.importance, Importance.high);
      expect(details.iOS!.interruptionLevel, isNot(InterruptionLevel.passive));
    });
  });
}
