import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/stores_controller.dart';
import 'package:karmashala/src/features/stores/presentation/store_app_card.dart';
import 'package:karmashala/src/features/stores/presentation/store_app_detail.dart';
import 'package:karmashala/src/features/stores/presentation/stores_tab_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:store_console/store_console.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';

/// The server's view already told, which never asks the server again.
class _Stores extends StoresController {
  _Stores(this._state);

  final StoresState _state;
  int refreshes = 0;
  int staleChecks = 0;

  @override
  Future<StoresState> build() async => _state;

  @override
  Future<void> refreshIfStale() async => staleChecks++;

  @override
  Future<void> refresh() async => refreshes++;

  final retried = <StoreApp>[];

  @override
  Future<String?> retry(StoreApp app) async {
    retried.add(app);
    return null;
  }
}

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

void main() {
  final now = DateTime.utc(2026, 9, 30, 9, 12);
  final apple = AppleKeySummary(
    keyId: 'KEYID',
    issuerId: 'issuer',
    importedAt: DateTime.utc(2026, 9, 29),
  );

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

  StoresState populated({
    bool refreshing = false,
    int done = 0,
    int total = 0,
    String? problem,
  }) => StoresState(
    view: StoresView(
      apple: apple,
      stores: {
        StoreKind.appStore: ReadingValue([notes, tasks], fixtureCheckedAt),
      },
      apps: [
        storeSnapshot(
          notes,
          releases: [
            storeRelease(
              ReleaseState.live,
              version: '2.3.0',
              track: 'App Store',
            ),
            storeRelease(
              ReleaseState.inReview,
              version: '2.4.0',
              track: 'App Store',
            ),
          ],
        ),
        storeSnapshot(
          tasks,
          rating: ReadingMissing(
            StoreFailure.network,
            'The App Store could not be reached.',
            fixtureCheckedAt,
          ),
        ),
      ],
      refreshedAt: now.subtract(const Duration(minutes: 12)),
      refreshing: refreshing,
    ),
    done: done,
    total: total,
    problem: problem,
  );

  Future<_Stores> pump(
    WidgetTester tester, {
    required Size size,
    StoresState state = const StoresState(),
    bool settle = true,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _Stores(state);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWithValue(FixedClock(now)),
          storesProvider.overrideWith(() => controller),
        ],
        child: const MaterialApp(home: StoresTabView()),
      ),
    );
    // A refresh under way spins, and a spinner never settles.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
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
      await pump(tester, size: size, state: populated());

      expect(tester.takeException(), isNull);
      expect(find.text('Updated 12 min ago · 2 listings'), findsOneWidget);
      expect(find.text('Google Play is not connected.'), findsOneWidget);
      expect(find.byType(StoreGroupCard), findsNWidgets(2));
      // In review sorts before the settled app, under its own heading.
      expect(
        tester.getTopLeft(find.text('Notes')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Tasks')).dy),
      );
      expect(find.text('IN PROGRESS · 1'), findsOneWidget);
      expect(find.text('2.3.0'), findsOneWidget);
      expect(find.text('2.4.0 · In review'), findsOneWidget);
      expect(find.text('4.6'), findsOneWidget);
      // A rating the store did not give is said with its reason, not a zero.
      expect(find.text('Rating unavailable'), findsOneWidget);
      expect(
        find.byTooltip(
          'App Store: rating could not be read. The App Store could not be '
          'reached.',
        ),
        findsOneWidget,
      );
    });
  }

  for (final size in [_phone, _desktop]) {
    final width = size.width.round();

    testWidgets('each app says where it stands in a read ($width)', (
      tester,
    ) async {
      final maps = storeApp(
        StoreKind.appStore,
        'com.example.maps',
        name: 'Maps',
      );
      final held = populated().view;
      final controller = await pump(
        tester,
        size: size,
        settle: false,
        state: StoresState(
          view: StoresView(
            apple: apple,
            stores: {
              StoreKind.appStore: ReadingValue([
                notes,
                tasks,
                maps,
              ], fixtureCheckedAt),
            },
            apps: held.apps,
            refreshedAt: held.refreshedAt,
            refreshing: true,
            reads: {
              notes.key: const StoreAppRead.reading(),
              tasks.key: StoreAppRead.failed(
                'The App Store did not answer.',
                now,
              ),
              maps.key: const StoreAppRead.queued(),
            },
          ),
          total: 3,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Reading…'), findsOneWidget);
      // In place of the numbers being read, not beside them.
      expect(find.text('4.6'), findsNothing);
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('The App Store did not answer.'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(TextButton, 'Retry'));
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      expect(controller.retried, [tasks]);
    });

    testWidgets('an app read and settled says how long ago ($width)', (
      tester,
    ) async {
      final held = populated().view;
      await pump(
        tester,
        size: size,
        state: StoresState(
          view: StoresView(
            apple: apple,
            stores: held.stores,
            apps: held.apps,
            refreshedAt: fixtureCheckedAt,
          ),
        ),
      );

      // fixtureCheckedAt is 72 minutes before the test's now.
      expect(find.text('Read 1 h ago'), findsNWidgets(2));
      expect(find.textContaining('As read'), findsNothing);
    });
  }

  testWidgets('opening the tab asks for a stale view to be read', (
    tester,
  ) async {
    final controller = await pump(tester, size: _desktop, state: populated());
    expect(controller.staleChecks, 1);
    expect(controller.refreshes, 0);
  });

  testWidgets('Refresh asks the controller, once', (tester) async {
    final controller = await pump(tester, size: _desktop, state: populated());

    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(controller.refreshes, 1);
  });

  testWidgets('a refresh under way shows how far it has got', (tester) async {
    await pump(
      tester,
      size: _desktop,
      state: populated(refreshing: true, done: 1, total: 2),
      settle: false,
    );

    expect(find.text('Updated 12 min ago · reading 1 of 2'), findsOneWidget);
    // TextButton.icon is a subclass, which byType would not match.
    final refresh = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Refresh'),
        matching: find.byWidgetPredicate((widget) => widget is TextButton),
      ),
    );
    expect(refresh.onPressed, isNull);
  });

  testWidgets('a refresh the server refused says why', (tester) async {
    await pump(
      tester,
      size: _desktop,
      state: populated(problem: 'The Karmashala server did not answer.'),
    );

    expect(find.text('The Karmashala server did not answer.'), findsOneWidget);
  });

  testWidgets('a card opens its detail beside the list at desktop width', (
    tester,
  ) async {
    await pump(tester, size: _desktop, state: populated());

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
    await pump(tester, size: _phone, state: populated());

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
