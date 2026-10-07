import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/shell_area.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/data/device_notification_store.dart';
import 'package:karmashala/src/features/settings/presentation/notifications_page.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';

ClientCapabilities _client({required bool desktop}) => ClientCapabilities(
  systemIntegration: desktop,
  osToasts: desktop,
  localNotifications: !desktop,
  localDevices: desktop,
  externalApps: desktop,
  fileDrop: desktop,
  relaunch: desktop,
  density: desktop ? UiDensity.pointer : UiDensity.touch,
  hostsServer: desktop,
  multicastLock: false,
  mediaPlayback: desktop,
  deviceName: 'test',
  camera: !desktop,
);

void main() {
  for (final (name, size, desktop) in const [
    ('desktop 1440x900', Size(1440, 900), true),
    ('desktop 390x844', Size(390, 844), true),
    ('phone 390x844', Size(390, 844), false),
  ]) {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('ks_notify_page_');
      // A level saved on the phone may still hold its file; Windows will
      // not delete an open one, so try again until it lands.
      addTearDown(
        () => tester.runAsync(() async {
          for (var tries = 0; ; tries++) {
            try {
              return dir.deleteSync(recursive: true);
            } on FileSystemException {
              if (tries == 40) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        }),
      );
      final server = FakeDataServer();
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          clientCapabilitiesProvider.overrideWithValue(
            _client(desktop: desktop),
          ),
          deviceNotificationStoreProvider.overrideWithValue(
            DeviceNotificationStore(directory: () async => dir),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: NotificationsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('$name: Notify me is three levels, each saying what it does', (
      tester,
    ) async {
      final container = await pump(tester);

      expect(find.text('Notify me'), findsOneWidget);
      for (final label in ['Everything', 'Only when I’m needed', 'Nothing']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.textContaining('wait quietly in the Inbox'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Only when I’m needed'));
      await tester.pumpAndSettle();
      expect(
        container.read(notificationSettingsControllerProvider).level,
        NotifyLevel.whenNeeded,
      );
    });

    testWidgets('$name: "only in the background" is the desktop\'s', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.text('Only while Karmashala is in the background'),
        desktop ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('$name: the chime is off until turned on, and the phone has '
        'none', (tester) async {
      final container = await pump(tester);
      final row = find.text('Chime when something needs you');
      if (!desktop) {
        expect(row, findsNothing);
        return;
      }
      final settings = notificationSettingsControllerProvider;
      expect(container.read(settings).chime, isFalse);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(container.read(settings).chime, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name: a link opens the Inbox on its quiet items', (
      tester,
    ) async {
      final container = await pump(tester);
      final link = find.widgetWithText(TextButton, 'Show in the Inbox');
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();

      expect(container.read(inboxShowQuietProvider), isTrue);
      if (desktop) {
        expect(container.read(shellAreaProvider), ShellArea.inbox);
      }
    });
  }
}
