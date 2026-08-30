import 'package:chitragupta/src/features/notifications/data/desktop_notification_presenter.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_session_key.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_policy.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_request.dart';
import 'package:chitragupta/src/features/notifications/domain/session_attention.dart';
import 'package:chitragupta/src/features/notifications/domain/watched_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tray_manager/tray_manager.dart';

/// End-to-end proof that Loop 42 reaches the operating system: a **real toast**
/// raised through `local_notifier`, and the **real tray icon** switched to its
/// badged state with the attention menu the watcher would build.
///
/// Deliberately does not run `main()`. Nothing here opens the app database or
/// writes `mcp_bridge.json`, so it is safe to run alongside a real instance.
///
/// Run with: `flutter test integration_test/notification_delivery_test.dart -d windows`.
///
/// A toast appears on the desktop for a few seconds and a second tray icon
/// shows up while it runs; both are expected.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  PendingNotification event(String id, String label, NotificationReason reason) =>
      PendingNotification(
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
      expect(presenter.isSupported, isTrue, reason: 'desktop host expected');

      // One agent finishing: the ordinary case.
      final single = const NotificationCoalescer().summarize([
        event('cli-1', 'Loop 42 — tray notifications', NotificationReason.finished),
      ])!;
      await presenter.show(single);
      await Future<void>.delayed(const Duration(seconds: 6));

      // Three at once: the burst the coalescer exists for.
      final burst = const NotificationCoalescer().summarize([
        event('cli-1', 'Fix login', NotificationReason.needsInput),
        event('cli-2', 'Write docs', NotificationReason.needsInput),
        event('cli-3', 'Ship release', NotificationReason.failed),
      ])!;
      expect(burst.title, '3 sessions need you');
      await presenter.show(burst);
      await Future<void>.delayed(const Duration(seconds: 8));

      // The presenter stays usable after delivering.
      expect(presenter.isSupported, isTrue);
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

      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Chitragupta');
      await Future<void>.delayed(const Duration(seconds: 2));

      // What `SystemIntegrationService._applyAttention` does, with the same
      // labels the watcher produces.
      await trayManager.setIcon('assets/tray_icon_attention.ico');
      await trayManager.setToolTip(
        'Chitragupta — ${waiting.length} sessions need you',
      );
      await trayManager.setContextMenu(
        Menu(
          items: [
            for (var i = 0; i < waiting.length; i++)
              MenuItem(key: 'attention:$i', label: waiting[i].menuLabel),
            MenuItem.separator(),
            MenuItem(key: 'show', label: 'Open Chitragupta'),
          ],
        ),
      );
      expect(waiting.first.menuLabel, 'Fix login — needs approval');
      expect(waiting.last.menuLabel, 'Ship release — failed');

      await Future<void>.delayed(const Duration(seconds: 10));
      await trayManager.destroy();
    });
  });
}
