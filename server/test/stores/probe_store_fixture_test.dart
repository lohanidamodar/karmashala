import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/src/stores/probe_store_fixture.dart';
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// A probe's stores from a file: only in a probe, and read afresh each call.
void main() {
  test('honoured only in a probe, and only when named', () {
    const named = {kProbeStoreFixtureVariable: 'C:/probe/stores.json'};
    expect(probeStoreFixture(named), isNull);
    expect(probeStoreFixture({...named, 'KARMASHALA_PROBE': '0'}), isNull);
    expect(probeStoreFixture({'KARMASHALA_PROBE': '1'}), isNull);
    expect(
      probeStoreFixture({...named, 'KARMASHALA_PROBE': 'on'})?.path,
      'C:/probe/stores.json',
    );
  });

  test('answers from the file as it stands at each call', () async {
    final dir = Directory.systemTemp.createTempSync('ks-store-fixture-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/stores.json');
    final at = DateTime.utc(2026, 10, 9);
    const app = StoreApp(
      store: StoreKind.appStore,
      id: '1',
      bundleId: 'com.example.probe',
      name: 'Probe',
    );
    void write(String raw) => file.writeAsStringSync(
      jsonEncode({
        'apps': [
          StoreAppSnapshot(
            app: app,
            releases: ReadingValue([
              StoreRelease(
                track: 'App Store',
                version: '1.0',
                state: ReleaseState.parse('live'),
                rawState: raw,
              ),
            ], at),
            reviews: ReadingValue(const [], at),
            rating: ReadingValue(const RatingSummary(average: 4), at),
            vitals: ReadingMissing(StoreFailure.notSupported, 'No.', at),
            downloads: ReadingMissing(StoreFailure.notConfigured, 'No.', at),
          ).toJson(),
        ],
      }),
    );
    final client = FixtureStoreClient(StoreKind.appStore, file);
    write('PENDING_DEVELOPER_RELEASE');
    expect(await client.listApps(), [app]);
    expect(
      (await client.releases(app)).single.rawState,
      'PENDING_DEVELOPER_RELEASE',
    );
    write('READY_FOR_SALE');
    expect((await client.releases(app)).single.rawState, 'READY_FOR_SALE');
    await expectLater(client.vitals(app), throwsA(isA<StoreException>()));
    expect(
      await FixtureStoreClient(StoreKind.googlePlay, file).listApps(),
      isEmpty,
    );
  });
}
