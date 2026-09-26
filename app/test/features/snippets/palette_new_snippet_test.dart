import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/snippets/application/snippet_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/workspace_mirror.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The palette's "New command snippet…" writes the snippet the user wrote.
///
/// It did not, and the loss was silent. `QuickOpenSources._newSnippet` awaited
/// the editor dialog and only then touched `ref` — but `ref` belongs to the
/// palette, and `dismiss` pops the palette *before* running the action, so by
/// the time Save is pressed `_QuickOpenState` is long unmounted. Riverpod 3's
/// `ConsumerStatefulElement._assertNotDisposed` **throws** there — a real
/// `throw`, not an assert, so release builds do it too — and the `add` never
/// ran. The snippet was never written to the dao and never entered state: lost
/// rather than stale, which is why "maybe a refresh will show it" never helped.
/// The terminal toolbar's snippet button reaches this same path, so it was the
/// most discoverable way to add a snippet in the app.
///
/// The fix is to resolve the notifier **before** the await, which is the
/// discipline `_openFile` in that file already uses for its messenger. This
/// test is the whole reason to keep it that way: nothing else notices, because
/// the exception is swallowed by the dialog's own future.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
  });
  tearDown(() => db.close());

  testWidgets('"New command snippet…" in the palette actually saves one', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db, data: data),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context, initialQuery: r'$'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The palette pops itself before opening the editor — which is what puts
    // its `ref` out of reach by the time Save is pressed.
    await tester.tap(find.text('New command snippet…'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Command'),
      'flutter test',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      container.read(commandSnippetsProvider),
      hasLength(1),
      reason: 'the snippet the user just wrote is nowhere: the add threw',
    );
    expect(
      container.read(commandSnippetsProvider).single.command,
      'flutter test',
    );
  });
}
