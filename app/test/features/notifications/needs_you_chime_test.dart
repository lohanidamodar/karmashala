import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/notifications/application/needs_you_chime.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/watched.dart';

/// **The chime**: off unless turned on; once for each new thing that needs
/// you; never while the dashboard is in front of you, in Focus, at Never,
/// under the OS's quiet, or on the phone.
void main() {
  final at = DateTime.utc(2026, 10, 7, 12);
  InboxItem item(String id, InboxItemKind kind) => InboxItem(
    session: WatchedSession(
      key: AgentSessionKey('claudeCode', id),
      label: 'Session $id',
      openId: 'row-$id',
      imported: false,
    ),
    kind: kind,
    at: at,
  );

  group('when it holds back', () {
    const on = NotificationSettings(chime: true);
    String? held({
      NotificationSettings settings = on,
      bool phone = false,
      bool focusMode = false,
      bool? osQuiet = false,
      bool windowFocused = false,
      bool dashboardOnScreen = false,
    }) => chimeHeldBecause(
      settings: settings,
      phone: phone,
      focusMode: focusMode,
      osQuiet: osQuiet,
      windowFocused: windowFocused,
      dashboardOnScreen: dashboardOnScreen,
    );

    test('off by default, and a missing key never turns it on', () {
      expect(const NotificationSettings().chime, isFalse);
      expect(NotificationSettings.fromJson(const {}).chime, isFalse);
      expect(held(settings: const NotificationSettings()), 'off');
      expect(
        NotificationSettings.fromJson(on.toJson()).chime,
        isTrue,
        reason: 'kept once turned on',
      );
    });

    test('plays when on and nothing asks for quiet', () {
      expect(held(), isNull);
      // Focused alone is not enough: the dashboard must be what is shown.
      expect(held(windowFocused: true), isNull);
      expect(held(dashboardOnScreen: true), isNull);
      // Nothing read the OS: that is not quiet.
      expect(held(osQuiet: null), isNull);
    });

    test('never while the dashboard is in front of you', () {
      expect(held(windowFocused: true, dashboardOnScreen: true), isNotNull);
    });

    test('never in Focus, at Never, under the OS\'s quiet, or on the '
        'phone', () {
      expect(held(focusMode: true), 'Focus is on');
      expect(
        held(settings: on.copyWith(level: NotifyLevel.nothing)),
        'Notify me is Never',
      );
      expect(held(osQuiet: true), 'the OS asks for quiet');
      expect(held(phone: true), 'on the phone');
    });
  });

  group('once per item', () {
    late int played;
    late String? holding;
    late NeedsYouChime chime;

    setUp(() {
      played = 0;
      holding = null;
      chime = NeedsYouChime(heldBecause: () => holding, play: () => played++);
    });

    test('what already waits at start is not new', () {
      chime.seed([item('a', InboxItemKind.needsApproval)]);
      chime.onInbox([item('a', InboxItemKind.needsApproval)]);
      expect(played, 0);
    });

    test('a new ask chimes once; the same item again does not', () {
      chime.onInbox([item('a', InboxItemKind.needsApproval)]);
      chime.onInbox([item('a', InboxItemKind.needsApproval)]);
      chime.onInbox([]);
      chime.onInbox([item('a', InboxItemKind.needsApproval)]);
      expect(played, 1);
    });

    test('several new at once are one chime; a failure counts, a finished '
        'turn does not', () {
      chime.onInbox([
        item('a', InboxItemKind.needsApproval),
        item('b', InboxItemKind.failed),
      ]);
      expect(played, 1);
      chime.onInbox([item('c', InboxItemKind.finished)]);
      expect(played, 1);
    });

    test('an item held back is not chimed later', () {
      holding = 'Focus is on';
      chime.onInbox([item('a', InboxItemKind.needsApproval)]);
      holding = null;
      chime.onInbox([item('a', InboxItemKind.needsApproval)]);
      expect(played, 0);
      chime.onInbox([
        item('a', InboxItemKind.needsApproval),
        item('b', InboxItemKind.needsApproval),
      ]);
      expect(played, 1);
    });
  });
}
