import 'dart:async';

import 'package:karmashala/src/features/notifications/data/desktop_notification_presenter.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';

/// Manual verification — raises a **real toast** and switches the **real tray
/// icon** to its badged state with the attention menu the watcher would build.
///
/// Run it explicitly:
///
///   flutter test -d windows tool/verification/notification_delivery_probe.dart
///
/// Needs an interactive Windows desktop with a visible notification area. A
/// toast appears and a second tray icon shows up while it runs; both are
/// expected, and the tray icon is destroyed on the way out.
///
/// Deliberately does not run `main()`. Nothing here opens the app database or
/// writes `mcp_bridge.json`, so it is safe to run alongside a real instance.
///
/// ## Why it is here and not in `integration_test/`
///
/// Until Loop 69 it was `integration_test/notification_delivery_test.dart`:
/// twenty-six seconds of fixed sleeps and not one assertion about OS delivery
/// or the tray. Its only real assertions — the coalescer's burst title and
/// `SessionAttention.menuLabel` — need no operating system at all and are
/// already covered hermetically by `notification_coalescer_test.dart` and
/// `agent_status_watcher_test.dart`, so they are not repeated here.
///
/// What *is* asserted is the one thing a fake cannot answer: that this
/// unpackaged app can get a toast into Windows at all, which depends on the
/// AUMID shortcut `ShortcutPolicy.requireCreate` creates on first use. That is
/// waited for, not slept through — see [_showTimeout].
///
/// The tray half has no callback to wait on: `Shell_NotifyIcon` reports nothing
/// back, so the badged icon and its menu have to be looked at. That is what
/// [_lookDwell] is for, and it is the reason this is a probe rather than a test.

/// How long to wait for the plugin to report that it handed the toast to
/// WinToast. Generous: the first run of an unpackaged app creates a Start Menu
/// shortcut before it can raise anything.
const _showTimeout = Duration(seconds: 20);

/// How long the badged tray icon and its menu stay up for the operator to look
/// at. Not a race — there is nothing to wait for, only something to see.
const _lookDwell = Duration(seconds: 10);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  PendingNotification event(
    String id,
    String label,
    NotificationReason reason,
  ) => PendingNotification(
    session: WatchedSession(
      key: AgentSessionKey('claudeCode', id),
      label: label,
      openId: 'row-$id',
      imported: true,
    ),
    reason: reason,
  );

  testWidgets('a coalesced notification reaches the OS', (tester) async {
    await tester.runAsync(() async {
      final presenter = DesktopNotificationPresenter();
      addTearDown(presenter.dispose);

      // The shipped path, end to end: the coalescer's own request through the
      // real presenter. One agent finishing, then the burst of three the
      // coalescer exists for.
      for (final pending in [
        [
          event(
            'cli-1',
            'Loop 42 — tray notifications',
            NotificationReason.finished,
          ),
        ],
        [
          event('cli-1', 'Fix login', NotificationReason.needsInput),
          event('cli-2', 'Write docs', NotificationReason.needsInput),
          event('cli-3', 'Ship release', NotificationReason.failed),
        ],
      ]) {
        await presenter.show(const NotificationCoalescer().summarize(pending)!);
      }

      // `show` swallows every failure by design, so this is the only thing it
      // reports: a refused `localNotifier.setup` latches `_unavailable` and
      // `isSupported` goes false for the rest of the process.
      expect(
        presenter.isSupported,
        isTrue,
        reason: 'the desktop refused to set the app up for notifications',
      );

      // ...and the observable the sleeps used to stand in for. The presenter
      // owns the `LocalNotification` it creates and does not expose it, so one
      // more is raised here rather than re-implementing `show`. `onShow` fires
      // once the plugin has handed the toast to WinToast — proof the channel
      // round trip and the AUMID both worked, not proof anyone saw it. Seeing
      // it is the operator's job.
      await localNotifier.setup(appName: 'Karmashala');
      final shown = Completer<void>();
      final probe =
          LocalNotification(
              title: 'Karmashala delivery probe',
              body: 'If you can read this, toasts work on this host.',
            )
            ..onShow = () {
              if (!shown.isCompleted) shown.complete();
            };
      addTearDown(() {
        try {
          probe.destroy();
        } catch (_) {}
      });
      await probe.show();
      await shown.future.timeout(
        _showTimeout,
        onTimeout: () => fail(
          'Windows did not raise the toast within '
          '${_showTimeout.inSeconds}s — the app has no AUMID shortcut, or '
          'notifications are switched off for it in Settings.',
        ),
      );
    });
  });

  testWidgets('the tray shows what needs the user', (tester) async {
    await tester.runAsync(() async {
      const waiting = [
        SessionAttention(
          session: WatchedSession(
            key: AgentSessionKey('claudeCode', 'cli-1'),
            label: 'Fix login',
            openId: 'row-1',
            imported: true,
          ),
          kind: AttentionKind.needsInput,
        ),
        SessionAttention(
          session: WatchedSession(
            key: AgentSessionKey('claudeCode', 'cli-2'),
            label: 'Ship release',
            openId: 'row-2',
            imported: true,
          ),
          kind: AttentionKind.failed,
        ),
      ];
      addTearDown(() async {
        try {
          await trayManager.destroy();
        } catch (_) {}
      });

      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Karmashala');

      // What `SystemIntegrationService._applyAttention` does, with the same
      // labels the watcher produces. Awaiting each call *is* the round trip to
      // `Shell_NotifyIcon`; there is no completion event to poll for, so
      // whether the badged icon is the one that appears has to be looked at.
      await trayManager.setIcon('assets/tray_icon_attention.ico');
      await trayManager.setToolTip(
        'Karmashala — ${waiting.length} sessions need you',
      );
      await trayManager.setContextMenu(
        Menu(
          items: [
            for (var i = 0; i < waiting.length; i++)
              MenuItem(key: 'attention:$i', label: waiting[i].menuLabel),
            MenuItem.separator(),
            MenuItem(key: 'show', label: 'Open Karmashala'),
          ],
        ),
      );

      await Future<void>.delayed(_lookDwell);
    });
  });
}
