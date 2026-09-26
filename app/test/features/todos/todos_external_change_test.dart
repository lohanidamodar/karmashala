import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';

/// **A change the panel did not make.**
///
/// The owner hit it once: two todos ticked off by another writer while the
/// panel drew them open until a restart — *"you said marked done but i don't
/// see the change."* Every write goes through the server, and the server
/// tells every other client what changed, so the panel is live with no poll
/// and no refresh on focus. The other writer is an agent's tool call or a
/// phone, as the server sees it.
void main() {
  Future<(ProviderContainer, FakeDataServer)> connected() async {
    final server = FakeDataServer();
    final client = await server.connect();
    final container = ProviderContainer(
      overrides: [dataClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    return (container, server);
  }

  void tickElsewhere(FakeDataServer server, String id) =>
      server.writeAsAnotherClient([
        TodoChanged(server.todos[id]!.copyWith(doneAt: DateTime.utc(2026))),
      ]);

  test('another client\'s write reaches the list without asking', () async {
    final (container, server) = await connected();
    final todo = await container
        .read(todosProvider.notifier)
        .addStored(body: 'Rework the tab strip');
    expect(container.read(todosProvider).single.isDone, isFalse);

    tickElsewhere(server, todo.id);

    expect(container.read(todosProvider).single.isDone, isTrue);
  });

  testWidgets('the open panel shows it, without a remount', (tester) async {
    final (container, server) = await connected();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final todo = await container
        .read(todosProvider.notifier)
        .addStored(body: 'Rework the tab strip');
    await tester.pumpWidget(
      UncontrolledProviderScope(
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
      ),
    );
    await tester.pumpAndSettle();
    bool ticked() =>
        tester.widget<Checkbox>(find.byType(Checkbox)).value ?? false;
    expect(ticked(), isFalse);
    final panelElement = tester.element(find.byType(TodosView));

    tickElsewhere(server, todo.id);
    await tester.pumpAndSettle();

    expect(ticked(), isTrue);
    expect(find.text('DONE'), findsOneWidget);
    expect(
      tester.element(find.byType(TodosView)),
      same(panelElement),
      reason: 'the same panel saw it; nothing was rebuilt from scratch',
    );
  });

  test('this client\'s own writes are not told back to it as news', () async {
    final (container, _) = await connected();
    await container.read(todosProvider.notifier).addStored(body: 'one');
    final before = container.read(todosProvider);
    await container
        .read(todosProvider.notifier)
        .setDoneStored(before.single.id, false);
    expect(container.read(todosProvider), same(before));
  });
}
