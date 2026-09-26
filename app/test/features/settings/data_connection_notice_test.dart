import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/settings/presentation/data_connection_notice.dart';
import 'package:karmashala_store/database.dart';

/// What Settings says when notes, todos and settings are not going through
/// the server.
void main() {
  test('connected says nothing; the fallback and a redial say why', () {
    expect(
      dataConnectionText(const DataConnection(DataLinkState.connected)),
      isNull,
    );
    expect(
      dataConnectionText(
        const DataConnection(DataLinkState.inProcess, 'the host is outdated'),
      ),
      allOf(contains('not reachable'), contains('the host is outdated')),
    );
    expect(
      dataConnectionText(const DataConnection(DataLinkState.reconnecting)),
      contains('wait'),
    );
  });

  testWidgets('where no server can run, nothing is drawn', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: DataConnectionNotice())),
      ),
    );
    expect(find.textContaining('Karmashala server'), findsNothing);
  });
}
