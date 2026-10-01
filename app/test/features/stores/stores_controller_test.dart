import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/stores/application/stores_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

import '../../support/fake_data_server.dart';
import 'store_fixtures.dart';

/// The Stores feature over the data protocol: the server holds the keys and
/// reads the stores; the controller only asks and listens.
void main() {
  final now = DateTime.utc(2026, 10, 1, 9);
  late FakeDataServer server;

  final notes = storeApp(
    StoreKind.appStore,
    'com.example.notes',
    name: 'Notes',
  );
  final apple = AppleKeySummary(
    keyId: 'KEYID',
    issuerId: 'issuer',
    vendorNumber: '8000',
    importedAt: DateTime.utc(2026, 9, 29),
  );

  Future<ProviderContainer> start() async {
    final client = await server.connect();
    final container = ProviderContainer(
      overrides: [dataClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    // Kept alive as the tab keeps it while open.
    container.listen(storesProvider, (_, _) {});
    await container.read(storesProvider.future);
    return container;
  }

  StoresController controller(ProviderContainer container) =>
      container.read(storesProvider.notifier);

  StoresState state(ProviderContainer container) =>
      container.read(storesProvider).requireValue;

  setUp(() {
    server = FakeDataServer(clock: () => now);
  });

  test('it starts from what the server holds, never a store', () async {
    server.stores.view = StoresView(
      apple: apple,
      stores: {
        StoreKind.appStore: ReadingValue([notes], fixtureCheckedAt),
      },
      apps: [storeSnapshot(notes)],
      refreshedAt: now.subtract(const Duration(minutes: 5)),
    );

    final container = await start();

    expect(server.requests, contains(StoresGet.name));
    expect(state(container).connected, {StoreKind.appStore});
    expect(state(container).groups.single.bundleId, 'com.example.notes');
    expect(state(container).refreshing, isFalse);
  });

  test('a change the server tells replaces the view, and progress is '
      'counted within one refresh', () async {
    server.stores.view = StoresView(apple: apple);
    final container = await start();

    server.stores.tell(StoresView(apple: apple, refreshing: true));
    server.stores.tellProgress(1, 3);
    await pumpEventQueue();
    expect(state(container).refreshing, isTrue);
    expect((state(container).done, state(container).total), (1, 3));

    server.stores.tell(
      StoresView(apple: apple, apps: [storeSnapshot(notes)], refreshedAt: now),
    );
    await pumpEventQueue();
    expect(state(container).refreshing, isFalse);
    expect((state(container).done, state(container).total), (0, 0));
    expect(state(container).refreshedAt, now);
    expect(state(container).groups, hasLength(1));
  });

  test('opening asks only for a view older than half an hour; Refresh '
      'always asks', () async {
    server.stores.view = StoresView(
      apple: apple,
      refreshedAt: now.subtract(const Duration(minutes: 10)),
    );
    final container = await start();

    await controller(container).refreshIfStale();
    await controller(container).refresh();

    expect(server.stores.refreshes, [1800, null]);
    expect(state(container).refreshedAt, now);
    expect(state(container).refreshing, isFalse);
  });

  test('with nothing connected nothing is refreshed', () async {
    final container = await start();

    await controller(container).refresh();

    expect(server.stores.refreshes, isEmpty);
  });

  test(
    'an imported key is sent once and only its summary comes back',
    () async {
      final container = await start();

      final problem = await controller(container).importAppleKey(
        pem: 'placeholder, not a key',
        keyId: ' KEYID ',
        issuerId: 'issuer',
        vendorNumber: '',
      );

      expect(problem, isNull);
      expect(server.stores.receivedKeys, ['placeholder, not a key']);
      final held = state(container).view.apple!;
      expect(held.keyId, 'KEYID');
      expect(held.vendorNumber, isNull);
      expect(state(container).connected, {StoreKind.appStore});
    },
  );

  test('changing the vendor number keeps the key the server holds', () async {
    server.stores.view = StoresView(apple: apple);
    final container = await start();

    expect(await controller(container).updateApple('9000'), isNull);

    expect(server.stores.receivedKeys, isEmpty);
    expect(state(container).view.apple?.vendorNumber, '9000');
    expect(state(container).view.apple?.importedAt, apple.importedAt);
  });

  test('the Play options are changed without the key, and removal forgets '
      'the store', () async {
    server.stores.view = StoresView(
      play: PlayAccountSummary(
        clientEmail: 'reader@example.iam',
        importedAt: DateTime.utc(2026, 9, 29),
      ),
    );
    final container = await start();

    expect(
      await controller(
        container,
      ).updatePlay(bucket: 'pubsite_prod_rev_1', packageNames: ['com.a.one']),
      isNull,
    );
    expect(state(container).view.play?.reportsBucket, 'pubsite_prod_rev_1');
    expect(state(container).view.play?.packageNames, ['com.a.one']);
    expect(server.stores.receivedKeys, isEmpty);

    expect(await controller(container).remove(StoreKind.googlePlay), isNull);
    expect(state(container).connected, isEmpty);
  });

  test('a blank form is refused here, before the server is asked', () async {
    final container = await start();

    expect(
      await controller(
        container,
      ).importAppleKey(pem: 'text', keyId: ' ', issuerId: 'issuer'),
      'Enter the key ID and the issuer ID.',
    );
    expect(server.requests, isNot(contains(StoreAppleSet.name)));
  });

  test('a phone refused a write is told where keys are imported', () async {
    server.stores
      ..view = StoresView(apple: apple)
      ..refuseWrites = true;
    final container = await start();

    final problem = await controller(container).remove(StoreKind.appStore);

    expect(problem, contains('imported in Karmashala on the desktop'));
    expect(state(container).connected, {StoreKind.appStore});
  });
}
