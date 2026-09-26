import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/data/in_process_data_endpoint.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_store/database.dart';

import '../../support/fixtures.dart';

/// **A change the panel did not make.**
///
/// The owner hit it once: two todos ticked off by another writer while the
/// panel drew them open until a restart — *"you said marked done but i don't
/// see the change."* Every write now goes through the server, and the server
/// tells every other client what changed, so the panel is live with no poll
/// and no refresh on focus. The other client here is a second data client of
/// the same service — an agent's tool call or a phone, as the server sees it.
void main() {
  ({ProviderContainer container, DataClient other}) twoClients() {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    final service = DataService(db);
    final app = DataClient.over(InProcessDataEndpoint.over(service));
    final other = DataClient.over(InProcessDataEndpoint.over(service));
    addTearDown(app.close);
    addTearDown(other.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        dataClientProvider.overrideWithValue(app),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, other: other);
  }

  Widget panel(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(width: 320, child: TodosView()),
            Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );

  bool ticked(WidgetTester tester) =>
      tester.widget<Checkbox>(find.byType(Checkbox)).value ?? false;

  test('another client\'s write reaches the list without asking', () async {
    final (:container, :other) = twoClients();
    final todo = container
        .read(todosProvider.notifier)
        .add(body: 'Rework the tab strip');
    expect(container.read(todosProvider).single.isDone, isFalse);

    await other.send(TodoSetDone(id: todo.id, done: true));

    expect(container.read(todosProvider).single.isDone, isTrue);
  });

  testWidgets('the open panel shows it, without a remount', (tester) async {
    final (:container, :other) = twoClients();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final todo = container
        .read(todosProvider.notifier)
        .add(body: 'Rework the tab strip');
    await tester.pumpWidget(panel(container));
    await tester.pumpAndSettle();
    expect(ticked(tester), isFalse);
    final panelElement = tester.element(find.byType(TodosView));

    await tester.runAsync(
      () => other.send(TodoSetDone(id: todo.id, done: true)),
    );
    await tester.pumpAndSettle();

    expect(ticked(tester), isTrue);
    expect(find.text('DONE'), findsOneWidget);
    expect(
      tester.element(find.byType(TodosView)),
      same(panelElement),
      reason: 'the same panel saw it; nothing was rebuilt from scratch',
    );
  });

  test('this client\'s own writes are not told back to it as news', () {
    final (:container, other: _) = twoClients();
    container.read(todosProvider.notifier).add(body: 'one');
    final before = container.read(todosProvider);
    container.read(todosProvider.notifier).setDone(before.single.id, false);
    expect(container.read(todosProvider), same(before));
  });
}
