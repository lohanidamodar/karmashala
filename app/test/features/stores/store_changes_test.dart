import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/activity_strip.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/data/device_notification_store.dart';
import 'package:karmashala/src/features/settings/presentation/notifications_page.dart';
import 'package:karmashala/src/features/stores/application/store_changes.dart';
import 'package:karmashala/src/features/stores/application/store_credentials.dart';
import 'package:karmashala/src/features/stores/application/stores_controller.dart';
import 'package:karmashala/src/features/stores/application/stores_layout_prefs.dart';
import 'package:karmashala/src/features/stores/presentation/stores_settings_section.dart';
import 'package:karmashala/src/features/stores/presentation/stores_tab_state.dart';
import 'package:karmashala/src/features/stores/presentation/stores_tab_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import 'store_fixtures.dart';

/// What changed in the stores, as the app shows it: the card's marker, the
/// detail's list, the badge, the notification and the two settings.
class _Stores extends StoresController {
  _Stores(this._state);

  final StoresState _state;
  final seen = <List<String>>[];

  @override
  Future<StoresState> build() async => _state;

  @override
  Future<void> refreshIfStale() async {}

  @override
  void markSeen(Iterable<String> appKeys) => seen.add(appKeys.toList());
}

class _Selected extends StoresSelection {
  _Selected(this._initial);

  final String? _initial;

  @override
  String? build() => _initial;
}

class _RecordingPresenter implements NotificationPresenter {
  final shown = <NotificationRequest>[];

  @override
  bool get isSupported => true;

  @override
  Future<void> show(NotificationRequest request) async => shown.add(request);

  @override
  void dispose() {}
}

const _desktopClient = ClientCapabilities(
  systemIntegration: true,
  osToasts: true,
  localNotifications: false,
  localDevices: true,
  externalApps: true,
  fileDrop: true,
  relaunch: true,
  density: UiDensity.pointer,
  hostsServer: true,
  multicastLock: false,
  mediaPlayback: true,
  deviceName: 'test',
  camera: false,
);

const _phone = Size(390, 844);
const _narrow = Size(360, 780);
const _desktop = Size(1440, 900);

void main() {
  final now = DateTime.utc(2026, 10, 9, 9);
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

  StoreAppChanges changed(
    StoreApp app, {
    bool seen = false,
    bool attention = true,
  }) => StoreAppChanges(
    app: app,
    platform: 'iOS',
    at: now.subtract(const Duration(minutes: 20)),
    seen: seen,
    changes: [
      StoreChange(
        kind: StoreChangeKind.release,
        text: '2.4.0 In review → Rejected',
        attention: attention,
      ),
      const StoreChange(
        kind: StoreChangeKind.reviews,
        text: '3 new reviews (lowest 4★)',
      ),
    ],
  );

  StoresState state(List<StoreAppChanges> changes) => StoresState(
    view: StoresView(
      apple: apple,
      stores: {
        StoreKind.appStore: ReadingValue([notes, tasks], fixtureCheckedAt),
      },
      apps: [storeSnapshot(notes), storeSnapshot(tasks)],
      refreshedAt: now.subtract(const Duration(minutes: 20)),
      changes: changes,
    ),
  );

  Future<_Stores> pumpTab(
    WidgetTester tester, {
    required Size size,
    required StoresState state,
    String? selected,
    double textScale = 1,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _Stores(state);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          clockProvider.overrideWithValue(FixedClock(now)),
          storesProvider.overrideWith(() => controller),
          storesSelectionProvider.overrideWith(() => _Selected(selected)),
          // The marker is the cards'; the table has its own bell.
          storesLayoutStoreProvider.overrideWithValue(
            MemoryStoresLayoutStore(StoresLayout.cards),
          ),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const StoresTabView(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  for (final size in [_phone, _desktop]) {
    final width = size.width.round();

    testWidgets('$width px: a card changed since it was opened says so', (
      tester,
    ) async {
      await pumpTab(
        tester,
        size: size,
        state: state([changed(notes), changed(tasks, seen: true)]),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('store-changed-marker')),
        findsOneWidget,
      );
      expect(find.text('Changed since last refresh'), findsOneWidget);
    });

    testWidgets('$width px: the detail opens on what changed, and sees it', (
      tester,
    ) async {
      final controller = await pumpTab(
        tester,
        size: size,
        state: state([changed(notes)]),
        selected: notes.key,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('WHAT CHANGED'), findsOneWidget);
      expect(find.text('2.4.0 In review → Rejected'), findsOneWidget);
      expect(find.text('3 new reviews (lowest 4★)'), findsOneWidget);
      expect(find.text('Found 20 min ago'), findsOneWidget);
      expect(controller.seen, [
        [notes.key],
      ]);
    });
  }

  testWidgets('at 360 px and text 1.6 the marker and list do not overflow', (
    tester,
  ) async {
    await pumpTab(
      tester,
      size: _narrow,
      textScale: 1.6,
      state: state([changed(notes)]),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Changed since last refresh'), findsOneWidget);
    await pumpTab(
      tester,
      size: _narrow,
      textScale: 1.6,
      state: state([changed(notes)]),
      selected: notes.key,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('WHAT CHANGED'), findsOneWidget);
  });

  testWidgets('an app with nothing changed has no marker and no list', (
    tester,
  ) async {
    final controller = await pumpTab(
      tester,
      size: _desktop,
      state: state(const []),
      selected: tasks.key,
    );
    expect(find.text('Changed since last refresh'), findsNothing);
    expect(find.text('WHAT CHANGED'), findsNothing);
    expect(controller.seen, isEmpty);
  });

  group('the badge', () {
    test('counts apps whose unseen changes want a person', () async {
      final server = FakeDataServer(clock: () => now);
      server.stores.view = StoresView(
        apple: apple,
        changes: [
          changed(notes),
          changed(tasks, attention: false),
          changed(storeApp(StoreKind.appStore, 'com.example.x'), seen: true),
        ],
      );
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      expect(container.read(storesUnseenAttentionProvider), 0);
      // As the server greets a subscriber, and tells a read's end.
      server.stores.tell(server.stores.view);
      await pumpEventQueue();
      expect(container.read(storesUnseenAttentionProvider), 1);
      expect(container.read(storesUnseenNewsProvider), isTrue);

      container.read(storeChangesProvider.notifier).seenHere({notes.key});
      expect(container.read(storesUnseenAttentionProvider), 0);
    });

    testWidgets('the strip draws it on the Stores glyph', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 700,
                child: ActivityStrip(
                  selected: null,
                  onSelect: (_) {},
                  onSettings: () {},
                  onStores: () {},
                  storesBadge: 2,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('2'), findsOneWidget);
      expect(find.bySemanticsLabel('Stores, 2 need you'), findsOneWidget);
    });
  });

  group('the notification', () {
    final loud = changed(notes);
    final quiet = changed(tasks, attention: false);

    test('attention only by default: a quiet change does not interrupt', () {
      const settings = NotificationSettings();
      expect(storeChangeNotification([quiet], settings), isNull);
      final request = storeChangeNotification([loud, quiet], settings)!;
      expect(request.title, 'Notes (iOS)');
      expect(request.body, loud.summary);
      expect(request.quiet, isFalse);
      expect(
        NotificationPayload.decode(request.payload)!.openId,
        storeInboxOpenId(notes.key),
      );
    });

    test('everything tells all, quietly when none wants a person', () {
      const settings = NotificationSettings(
        storeChanges: StoreChangeNotify.everything,
      );
      expect(storeChangeNotification([quiet], settings)!.quiet, isTrue);
      final both = storeChangeNotification([loud, quiet], settings)!;
      expect(both.title, '2 apps changed in the stores');
      expect(both.body, 'Notes (iOS) · Tasks (iOS)');
    });

    test('off, or Notify me at Never, tells nothing', () {
      expect(
        storeChangeNotification([
          loud,
        ], const NotificationSettings(storeChanges: StoreChangeNotify.off)),
        isNull,
      );
      expect(
        storeChangeNotification([
          loud,
        ], const NotificationSettings(level: NotifyLevel.nothing)),
        isNull,
      );
    });

    test(
      'a read the server tells goes up once, and not while looked at',
      () async {
        final server = FakeDataServer(clock: () => now);
        server.stores.view = StoresView(apple: apple);
        final presenter = _RecordingPresenter();
        final container = ProviderContainer(
          overrides: [
            await server.override(),
            notificationPresenterProvider.overrideWithValue(presenter),
          ],
        );
        addTearDown(container.dispose);
        container.listen(storeChangeNoticesProvider, (_, _) {});
        container.read(windowFocusedProvider.notifier).set(false);

        server.stores.notice([loud]);
        await pumpEventQueue();
        expect(presenter.shown.single.title, 'Notes (iOS)');

        container.read(windowFocusedProvider.notifier).set(true);
        server.stores.notice([loud]);
        await pumpEventQueue();
        expect(presenter.shown, hasLength(1), reason: 'the window is in front');
      },
    );
  });

  group('settings at 360 px and text 1.6', () {
    Future<(FakeDataServer, ProviderContainer)> pumpSettings(
      WidgetTester tester,
      Widget child,
    ) async {
      tester.view
        ..physicalSize = _narrow
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('ks_store_settings_');
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
      final server = FakeDataServer(clock: () => now);
      server.stores.view = StoresView(
        apple: apple,
        schedule: StoreRefreshSchedule(
          every: const Duration(hours: 3),
          nextAt: now.add(const Duration(hours: 2)),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(now)),
          storeCredentialsWritableProvider.overrideWithValue(true),
          deviceNotificationStoreProvider.overrideWithValue(
            DeviceNotificationStore(directory: () async => dir),
          ),
          clientCapabilitiesProvider.overrideWithValue(_desktopClient),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: _narrow,
                textScaler: TextScaler.linear(1.6),
              ),
              child: Scaffold(body: SingleChildScrollView(child: child)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (server, container);
    }

    testWidgets('Stores: the background read is chosen at the server', (
      tester,
    ) async {
      final (server, _) = await pumpSettings(
        tester,
        const StoresSettingsSection(),
      );
      expect(tester.takeException(), isNull);
      final row = find.byKey(const ValueKey('settings-store-background'));
      expect(row, findsOneWidget);
      expect(find.text('Every 3 hours'), findsOneWidget);

      await tester.ensureVisible(row);
      await tester.tap(find.text('Every 3 hours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every 12 hours').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(server.stores.schedules, [const Duration(hours: 12)]);
    });

    testWidgets('Notifications: store changes, attention only by default', (
      tester,
    ) async {
      final (_, container) = await pumpSettings(
        tester,
        const NotificationsSection(),
      );
      expect(tester.takeException(), isNull);
      final row = find.byKey(const ValueKey('settings-store-changes'));
      expect(row, findsOneWidget);
      expect(find.text('Only what needs me'), findsOneWidget);

      await tester.ensureVisible(row);
      await tester.tap(find.text('Only what needs me'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Everything').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        container.read(notificationSettingsControllerProvider).storeChanges,
        StoreChangeNotify.everything,
      );
    });
  });
}
