import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';

import 'explorer_fixture.dart';

class _Editing extends Notifier<EnvironmentPath?> {
  @override
  EnvironmentPath? build() => null;

  void open(EnvironmentPath? path) => state = path;
}

final _editing = NotifierProvider<_Editing, EnvironmentPath?>(_Editing.new);

/// The Files panel follows the file being edited, while it is open.
void main() {
  const root = '/src/app';
  final listings = {
    root: [dirEntry('$root/lib')],
    '$root/lib': [fileEntry('$root/lib/main.dart')],
  };

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    EnvironmentPath? editing,
  }) async {
    final container = ProviderContainer(
      overrides: explorerOverrides(
        root,
        listings,
        editing: (ref) => ref.watch(_editing) ?? editing,
      ),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FileExplorerView())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('a file under the folder is opened down to and selected', (
    tester,
  ) async {
    final c = await pump(tester);
    c.read(_editing.notifier).open(at('$root/lib/main.dart'));
    await tester.pumpAndSettle();

    expect(c.read(fileRevealTargetProvider)?.path, at('$root/lib/main.dart'));
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('a file elsewhere — or the same path on another machine — '
      'moves nothing', (tester) async {
    final c = await pump(tester);
    c.read(_editing.notifier).open(at('/elsewhere/notes.md'));
    await tester.pumpAndSettle();
    expect(c.read(fileRevealTargetProvider), isNull);

    c
        .read(_editing.notifier)
        .open(at('$root/lib/main.dart').copyWith(environmentId: 'ssh:box'));
    await tester.pumpAndSettle();
    expect(c.read(fileRevealTargetProvider), isNull);
  });

  testWidgets('a file already being edited is found when the panel opens', (
    tester,
  ) async {
    final c = await pump(tester, editing: at('$root/lib/main.dart'));
    expect(c.read(fileRevealTargetProvider)?.path, at('$root/lib/main.dart'));
  });
}
