import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/purge_progress.dart';
import 'package:karmashala/src/features/server/application/server_storage.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/server/presentation/server_storage_section.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ServerMethod;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Settings → Server → Storage: what the server keeps on disk, the tool-image
/// cache's limits, and cleaning up old ended sessions — only when asked.
void main() {
  final now = DateTime.utc(2026, 10, 6, 12);

  Map<String, Object?> reading({int files = 3, int bytes = 1536 * 1024}) => {
    'databaseBytes': 12 * 1024 * 1024,
    'tables': [
      {'name': 'session_events', 'bytes': 8 * 1024 * 1024},
      {'name': 'sessions', 'bytes': 2 * 1024 * 1024},
    ],
    'toolImages': {
      'files': files,
      'bytes': bytes,
      'maxAgeDays': 14,
      'maxMegabytes': 256,
    },
  };

  Future<(ProviderContainer, List<String>, FakeDataServer)> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    List<Session> sessions = const [],
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    var current = reading();
    final server = FakeDataServer();
    for (final row in sessions) {
      server.sessionRows.insert(row);
    }
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
        serverStorageClientProvider.overrideWithValue(
          ServerStorageClient((method) async {
            calls.add(method);
            if (method == ServerMethod.toolImagesClear) {
              current = reading(files: 0, bytes: 0);
              return {'removed': 3};
            }
            if (method == ServerMethod.toolImagesSweep) return {'removed': 1};
            return current;
          }),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ServerStorageSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, calls, server);
  }

  testWidgets('says how big the database is, and its largest tables', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text(SettingsAnchor.serverStorage.heading), findsOneWidget);
    expect(find.text('12.0 MB'), findsOneWidget);
    expect(
      find.text('session_events 8.0 MB · sessions 2.0 MB'),
      findsOneWidget,
    );
  });

  testWidgets('says what the tool-image cache holds, and Clear empties it '
      'after asking', (tester) async {
    final (_, calls, _) = await pump(tester);

    expect(find.text('3 files · 1.5 MB'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear the tool-image cache?'), findsOneWidget);
    expect(calls, [ServerMethod.storage]);

    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(calls, [
      ServerMethod.storage,
      ServerMethod.toolImagesClear,
      ServerMethod.storage,
    ]);
    expect(find.text('0 files · 0 B'), findsOneWidget);
  });

  testWidgets('the cache limits are adjustable, stored, and swept by at once', (
    tester,
  ) async {
    final (container, calls, _) = await pump(tester);

    await tester.tap(find.text('14 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 days').last);
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).toolImageMaxAgeDays, 30);

    await tester.tap(find.text('256 MB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 GB').last);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).toolImageMaxMegabytes,
      1024,
    );
    expect(
      calls.where((c) => c == ServerMethod.toolImagesSweep),
      hasLength(2),
    );
  });

  group('old ended sessions', () {
    List<Session> rows() => [
      // Started in January: older than 30 days.
      session(id: 'old-done', title: 'Old done', status: SessionStatus.completed),
      session(id: 'old-failed', title: 'Old failed', status: SessionStatus.failed),
      session(id: 'old-running', status: SessionStatus.running),
      session(
        id: 'new-done',
        status: SessionStatus.completed,
      ).copyWith(createdAt: now.subtract(const Duration(days: 2))),
    ];

    testWidgets('are counted, and nothing goes until Clean up is confirmed', (
      tester,
    ) async {
      final (container, _, server) = await pump(tester, sessions: rows());

      expect(
        find.text('2 ended sessions started more than 30 days ago.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Clean up'));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 sessions?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(server.sessionRows.getById('old-done'), isNotNull);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clean up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete 2 sessions'));
      await tester.pumpAndSettle();
      await container.read(sessionsDataProvider).settled();
      expect(server.sessionRows.getById('old-done'), isNull);
      expect(server.sessionRows.getById('old-failed'), isNull);
      expect(server.sessionRows.getById('old-running'), isNotNull);
      expect(server.sessionRows.getById('new-done'), isNotNull);
      expect(container.read(purgeProgressProvider), 0);
    });

    testWidgets('the age is a setting, and none found offers nothing', (
      tester,
    ) async {
      final (container, _, _) = await pump(tester);

      expect(find.text('No ended sessions started more than 30 days ago.'),
          findsOneWidget);
      final cleanUp = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Clean up'),
      );
      expect(cleanUp.onPressed, isNull);

      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('90 days').last);
      await tester.pumpAndSettle();
      expect(
        container.read(settingsControllerProvider).endedSessionsOlderThanDays,
        90,
      );
    });
  });

  testWidgets('fits a phone-width window', (tester) async {
    await pump(tester, size: const Size(390, 844), sessions: [
      session(id: 'old-done', status: SessionStatus.completed),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.text('Clean up'), findsOneWidget);
  });

  test('a phone does not list the section: the storage is the server\'s', () {
    final phone = Capabilities(
      client: ClientCapabilities(
        systemIntegration: false,
        osToasts: false,
        localNotifications: true,
        localDevices: false,
        externalApps: false,
        fileDrop: false,
        relaunch: false,
        density: UiDensity.touch,
        hostsServer: false,
        multicastLock: true,
        mediaPlayback: false,
        deviceName: 'phone',
        camera: true,
      ),
      server: const ServerOffer(sameMachine: false),
    );
    expect(SettingsAnchor.serverStorage.shownWith(phone), isFalse);
    expect(SettingsAnchor.serverStatus.shownWith(phone), isTrue);
  });

  test('reads a reading without tables as one that cannot say', () {
    final parsed = ServerStorageReading.fromJson({
      'databaseBytes': 10,
      'toolImages': {'files': 1, 'bytes': 2, 'maxAgeDays': 3, 'maxMegabytes': 4},
    });
    expect(parsed.tables, isNull);
    expect(parsed.toolImageFiles, 1);
  });
}
