import 'dart:io' show SocketException;

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/acp_agent_icon_backfill.dart';
import 'package:karmashala/src/features/agents/application/acp_agent_providers.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_http_client.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// A registry-sourced row kept without its icon — saved before icons were
/// stored, or whose entry gained one since — gets the icon its entry names
/// the next time the catalog is in hand, and nothing else is touched.
void main() {
  const registryJson = '''
{"agents": [
  {"id": "cursor", "name": "Cursor", "version": "1.0.0",
   "icon": "https://cdn.example.test/registry/cursor.svg",
   "distribution": {"npx": {"package": "cursor-agent@1.0.0"}}},
  {"id": "plain", "name": "Plain Agent", "version": "1.0.0",
   "distribution": {"npx": {"package": "plain-agent@1.0.0"}}}
]}''';

  late TestMachine db;
  late FakeHttpClient http;
  late ProviderContainer container;

  AcpAgentRow row(
    String id, {
    String? registryId,
    String? iconUrl,
    AcpAgentSource source = AcpAgentSource.registry,
  }) => AcpAgentRow(
    id: id,
    name: id,
    command: 'npx',
    args: const ['-y', 'x'],
    env: const {'A': '1'},
    source: source,
    registryId: registryId,
    iconUrl: iconUrl,
    createdAt: testTime,
  );

  setUp(() async {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    http = FakeHttpClient(body: registryJson);
    container = ProviderContainer(
      overrides: [
        await db.server.override(),
        acpRegistryHttpClientProvider.overrideWithValue(() => http),
      ],
    );
    addTearDown(container.dispose);
  });

  AcpAgentIconBackfill backfill() =>
      container.read(acpAgentIconBackfillProvider);

  test(
    'fills in the icon the entry names, and leaves every other row',
    () async {
      db.server.acpAgentRows
        ..insert(row('c', registryId: 'cursor'))
        ..insert(
          row(
            'k',
            registryId: 'cursor',
            iconUrl: 'https://cdn.example.test/registry/kept.svg',
          ),
        )
        ..insert(row('mine', source: AcpAgentSource.custom));
      expect(backfill().missing.map((r) => r.id), ['c']);

      expect(await backfill().fillMissing(), 1);

      final rows = {for (final r in db.server.acpAgentRows.getAll()) r.id: r};
      expect(
        rows['c']!.iconUrl,
        'https://cdn.example.test/registry/cursor.svg',
      );
      // The rest of the row is as it was.
      expect(rows['c']!.args, ['-y', 'x']);
      expect(rows['c']!.env, {'A': '1'});
      expect(rows['c']!.source, AcpAgentSource.registry);
      expect(rows['c']!.registryId, 'cursor');
      expect(rows['k']!.iconUrl, 'https://cdn.example.test/registry/kept.svg');
      expect(rows['mine']!.iconUrl, isNull);
      expect(http.requestedUrls, [Uri.parse(AcpRegistryCatalog.registryUrl)]);

      // Nothing left to fill: the catalog is not fetched again.
      expect(await backfill().fillMissing(), 0);
      expect(http.requests, 1);
    },
  );

  test('a catalog in hand fills with no fetch', () async {
    db.server.acpAgentRows.insert(row('c', registryId: 'cursor'));
    expect(
      await backfill().fillFrom(AcpRegistryCatalog.parse(registryJson)),
      1,
    );
    expect(db.server.acpAgentRows.getById('c')!.iconUrl, isNotNull);
    expect(http.requests, 0);
  });

  test('an entry that names no icon is asked about once a run', () async {
    db.server.acpAgentRows.insert(row('p', registryId: 'plain'));
    expect(await backfill().fillMissing(), 0);
    expect(http.requests, 1);
    expect(db.server.acpAgentRows.getById('p')!.iconUrl, isNull);
    expect(backfill().missing, isEmpty);
    expect(await backfill().fillMissing(), 0);
    expect(http.requests, 1);
  });

  test('an unreachable registry leaves the rows to be asked again', () async {
    db.server.acpAgentRows.insert(row('c', registryId: 'cursor'));
    http.throwOnRequest = const SocketException('offline');
    expect(await backfill().fillMissing(), 0);
    expect(db.server.acpAgentRows.getById('c')!.iconUrl, isNull);
    expect(backfill().missing.map((r) => r.id), ['c']);
  });

  test('with every row iconed nothing is fetched', () async {
    db.server.acpAgentRows.insert(
      row('k', registryId: 'cursor', iconUrl: 'https://x.test/k.svg'),
    );
    expect(await backfill().fillMissing(), 0);
    expect(http.requests, 0);
  });
}
