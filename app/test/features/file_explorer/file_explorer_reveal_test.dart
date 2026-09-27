import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';

import 'explorer_fixture.dart';

/// Going to a path in the Files panel.
///
/// The panel's tree is **lazy**: a folder is listed only once it is opened, and
/// the listing is async. So a reveal is a sequence, not a frame — each folder
/// on the way opens, its listing arrives, and the rows it produces ask the same
/// question in turn. These pin that the sequence completes from every starting
/// point, that the leaf is *selected* and not opened, and that the rows either
/// side of the path down are not redrawn for it.
void main() {
  const root = r'C:\src\app';
  const target = r'C:\src\app\lib\src\app.dart';

  final listings = {
    root: [
      dirEntry(r'C:\src\app\lib'),
      fileEntry(r'C:\src\app\pubspec.yaml'),
      // Enough siblings that "every row rebuilt" and "the rows on the way
      // rebuilt" are different numbers.
      for (var i = 0; i < 20; i++) fileEntry('C:\\src\\app\\other-$i.txt'),
    ],
    r'C:\src\app\lib': [
      dirEntry(r'C:\src\app\lib\src'),
      fileEntry(r'C:\src\app\lib\main.dart'),
    ],
    r'C:\src\app\lib\src': [fileEntry(target)],
  };

  late ProviderContainer container;

  setUp(() => debugFileRowBuilds = 0);

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer(overrides: explorerOverrides(root, listings));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 320, child: FileExplorerView())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void reveal({bool isDirectory = false, String path = target}) => container
      .read(fileRevealTargetProvider.notifier)
      .reveal(FileRevealTarget(path: at(path), isDirectory: isDirectory));

  /// The row's background, which is null for every row but the selected one.
  Color? rowColour(WidgetTester tester, String name) => tester
      .widget<Container>(
        find
            .ancestor(of: find.text(name), matching: find.byType(Container))
            .first,
      )
      .color;

  testWidgets('a target opens the tree down to it and selects the leaf', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('app.dart'), findsNothing);

    reveal();
    await tester.pumpAndSettle();

    expect(find.text('src'), findsOneWidget);
    expect(find.text('app.dart'), findsOneWidget);
    expect(rowColour(tester, 'app.dart'), isNotNull);
    expect(find.text('Opening in editor…'), findsNothing);
    expect(rowColour(tester, 'main.dart'), isNull);
    expect(rowColour(tester, 'pubspec.yaml'), isNull);
  });

  testWidgets('a target that arrived while the panel was closed is honoured '
      'when it opens', (tester) async {
    container = ProviderContainer(overrides: explorerOverrides(root, listings));
    addTearDown(container.dispose);
    reveal();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 320, child: FileExplorerView())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('app.dart'), findsOneWidget);
  });

  testWidgets('a folder target opens it rather than selecting a file', (
    tester,
  ) async {
    await pump(tester);

    reveal(path: r'C:\src\app\lib\src', isDirectory: true);
    await tester.pumpAndSettle();

    expect(find.text('app.dart'), findsOneWidget);
    expect(rowColour(tester, 'src'), isNotNull);
  });

  testWidgets('a reveal redraws the rows on the way to it and no others', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('app.dart'), findsOneWidget);

    debugFileRowBuilds = 0;
    reveal();
    await tester.pumpAndSettle();

    // The two folders on the way and the leaf; every other row's `select`
    // saw no change.
    expect(debugFileRowBuilds, 3);
  });

  testWidgets('clearing the target lets go of the selection', (tester) async {
    await pump(tester);
    reveal();
    await tester.pumpAndSettle();

    container.read(fileRevealTargetProvider.notifier).clear();
    await tester.pumpAndSettle();

    expect(find.text('app.dart'), findsOneWidget);
    expect(rowColour(tester, 'app.dart'), isNull);
  });

  test('the same path in another environment is another row', () {
    const wsl = 'wsl:Ubuntu';
    final target = FileRevealTarget(path: at('/home/me/a'), isDirectory: false);
    expect(
      fileRevealRoleFor(target, at('/home/me/a'), isDirectory: false),
      FileRevealRole.target,
    );
    expect(
      fileRevealRoleFor(
        target,
        at('/home/me/a').copyWith(environmentId: wsl),
        isDirectory: false,
      ),
      FileRevealRole.none,
    );
  });
}
