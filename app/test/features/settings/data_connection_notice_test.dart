import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/settings/presentation/data_connection_notice.dart';

import '../../support/fake_data_server.dart';

/// What the app says where notes, todos and settings are when the server is
/// not reachable — it never keeps them itself.
void main() {
  test('connected says nothing; starting and not running say so', () {
    expect(
      dataConnectionText(const DataConnection(DataLinkState.connected)),
      isNull,
    );
    expect(
      dataConnectionText(const DataConnection(DataLinkState.connecting)),
      contains('Starting the Karmashala server'),
    );
    expect(
      dataConnectionText(
        const DataConnection(DataLinkState.unavailable, 'the host is outdated'),
      ),
      allOf(contains('isn\'t running'), contains('the host is outdated')),
    );
  });

  Widget notice(List<Override> overrides) => ProviderScope(
    overrides: overrides,
    child: const MaterialApp(home: Scaffold(body: DataConnectionNotice())),
  );

  testWidgets('connected, nothing is drawn', (tester) async {
    final server = FakeDataServer();
    final data = await server.override();
    await tester.pumpWidget(notice([data]));
    expect(find.byKey(const ValueKey('data_connection_notice')), findsNothing);
  });

  testWidgets('no server: the reason and Retry, which dials again', (
    tester,
  ) async {
    final server = FakeDataServer()..stop();
    final client = await DataClient.connect(
      server.dial,
      unavailableReason: 'failed: no binary',
    );
    addTearDown(client.close);
    await tester.pumpWidget(
      notice([dataClientProvider.overrideWithValue(client)]),
    );
    expect(find.textContaining('failed: no binary'), findsOneWidget);

    server.start();
    await tester.tap(find.byKey(const ValueKey('data_connection_retry')));
    await tester.pump();
    await tester.pump();
    expect(client.connection.state, DataLinkState.connected);
    expect(find.byKey(const ValueKey('data_connection_notice')), findsNothing);
  });
}
