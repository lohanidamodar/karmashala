import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_credentials.dart';
import 'package:karmashala/src/features/stores/application/stores_dashboard.dart';
import 'package:karmashala/src/features/stores/presentation/store_app_card.dart';
import 'package:karmashala/src/features/stores/presentation/store_app_detail.dart';
import 'package:karmashala/src/features/stores/presentation/stores_tab_view.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';

class _Credentials extends StoreCredentialsController {
  _Credentials(this._credentials);

  final StoreCredentials _credentials;

  @override
  Future<StoreCredentials> build() async => _credentials;
}

/// A dashboard already read, which never reaches for a store.
class _Dashboard extends StoresDashboardController {
  _Dashboard(this._dashboard);

  final StoresDashboard _dashboard;
  int refreshes = 0;

  @override
  Future<StoresDashboard> build() async => _dashboard;

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> refresh() async => refreshes++;
}

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

void main() {
  // Not a key: text the import form would refuse as one.
  const apple = AppleApiKey(
    keyId: 'KEYID',
    issuerId: 'issuer',
    privateKeyPem: 'placeholder',
  );
  final now = DateTime.utc(2026, 9, 30, 9, 12);

  final notes = storeApp(
    StoreKind.appStore,
    'com.example.notes',
    name: 'Notes',
  );
  final tasks = storeApp(
    StoreKind.appStore,
    'com.example.tasks',
    name: 'Tasks',
  );

  StoresDashboard populated() => StoresDashboard(
    stores: {
      StoreKind.appStore: ReadingValue([notes, tasks], fixtureCheckedAt),
    },
    snapshots: {
      notes: storeSnapshot(
        notes,
        releases: [
          storeRelease(ReleaseState.live, version: '2.3.0', track: 'App Store'),
          storeRelease(
            ReleaseState.inReview,
            version: '2.4.0',
            track: 'App Store',
          ),
        ],
      ),
      tasks: storeSnapshot(
        tasks,
        rating: ReadingMissing(
          StoreFailure.network,
          'The App Store could not be reached.',
          fixtureCheckedAt,
        ),
      ),
    },
    refreshedAt: now.subtract(const Duration(minutes: 12)),
  );

  Future<_Dashboard> pump(
    WidgetTester tester, {
    required Size size,
    StoreCredentials credentials = const StoreCredentials(),
    StoresDashboard dashboard = const StoresDashboard(),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _Dashboard(dashboard);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWithValue(FixedClock(now)),
          storeCredentialsProvider.overrideWith(
            () => _Credentials(credentials),
          ),
          storesDashboardProvider.overrideWith(() => controller),
        ],
        child: const MaterialApp(home: StoresTabView()),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  for (final size in [_phone, _desktop]) {
    final width = size.width.round();

    testWidgets('with no credential it says what it is and where to begin '
        '($width)', (tester) async {
      await pump(tester, size: size);

      expect(tester.takeException(), isNull);
      expect(find.byType(PanePlaceholder), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Open Settings → Stores'),
        findsOneWidget,
      );
      expect(find.text('Refresh'), findsNothing);
    });

    testWidgets('shows each app, its age and the store that is not connected '
        '($width)', (tester) async {
      await pump(
        tester,
        size: size,
        credentials: const StoreCredentials(apple: apple),
        dashboard: populated(),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Updated 12 min ago'), findsOneWidget);
      expect(find.text('Google Play is not connected.'), findsOneWidget);
      expect(find.byType(StoreGroupCard), findsNWidgets(2));
      // In review sorts before the settled app.
      expect(
        tester.getTopLeft(find.text('Notes')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Tasks')).dy),
      );
      expect(find.text('2.3.0'), findsOneWidget);
      expect(find.text('In review'), findsOneWidget);
      expect(find.text('4.6 ★ (1.2k)'), findsOneWidget);
      // A rating the store did not give is a dash with its reason, not a zero.
      expect(find.text('Rating —'), findsOneWidget);
      expect(
        find.byTooltip('Rating: The App Store could not be reached.'),
        findsOneWidget,
      );
    });
  }

  testWidgets('Refresh asks the controller, once', (tester) async {
    final controller = await pump(
      tester,
      size: _desktop,
      credentials: const StoreCredentials(apple: apple),
      dashboard: populated(),
    );

    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(controller.refreshes, 1);
  });

  testWidgets('a card opens its detail beside the list at desktop width', (
    tester,
  ) async {
    await pump(
      tester,
      size: _desktop,
      credentials: const StoreCredentials(apple: apple),
      dashboard: populated(),
    );

    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(StoreGroupDetail), findsOneWidget);
    expect(find.byType(StoreGroupCard), findsNWidgets(2));
    expect(find.text('RELEASES'), findsOneWidget);
    expect(find.text('Thank you.'), findsOneWidget);
    expect(find.byTooltip('Close details'), findsOneWidget);
  });

  testWidgets('and in the place of the dashboard on a phone, with a way back', (
    tester,
  ) async {
    await pump(
      tester,
      size: _phone,
      credentials: const StoreCredentials(apple: apple),
      dashboard: populated(),
    );

    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(StoreGroupDetail), findsOneWidget);
    expect(find.byType(StoreGroupCard), findsNothing);

    await tester.tap(find.byTooltip('Back to all apps'));
    await tester.pumpAndSettle();
    expect(find.byType(StoreGroupCard), findsNWidgets(2));
  });
}
