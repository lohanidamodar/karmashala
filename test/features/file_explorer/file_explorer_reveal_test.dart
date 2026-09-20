import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

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

  /// Enough siblings at the root that "every row rebuilt" and "the rows on the
  /// way rebuilt" are different numbers.
  final crowd = <DirEntry>[
    for (var i = 0; i < 20; i++)
      DirEntry(
        name: 'other-$i.txt',
        isDirectory: false,
        windowsPath: 'C:\\src\\app\\other-$i.txt',
      ),
  ];

  final listings = <String, List<DirEntry>>{
    root: [
      const DirEntry(
        name: 'lib',
        isDirectory: true,
        windowsPath: r'C:\src\app\lib',
      ),
      const DirEntry(
        name: 'pubspec.yaml',
        isDirectory: false,
        windowsPath: r'C:\src\app\pubspec.yaml',
      ),
      ...crowd,
    ],
    r'C:\src\app\lib': const [
      DirEntry(
        name: 'src',
        isDirectory: true,
        windowsPath: r'C:\src\app\lib\src',
      ),
      DirEntry(
        name: 'main.dart',
        isDirectory: false,
        windowsPath: r'C:\src\app\lib\main.dart',
      ),
    ],
    r'C:\src\app\lib\src': const [
      DirEntry(
        name: 'app.dart',
        isDirectory: false,
        windowsPath: r'C:\src\app\lib\src\app.dart',
      ),
    ],
  };

  late ProviderContainer container;

  setUp(() => debugFileRowBuilds = 0);

  /// Every row asks [RevealInFileManager.canReveal] while building its
  /// right-click menu, so the panel cannot be pumped without one.
  // Return type inferred: Riverpod's `Override` is not an exported type.
  panelOverrides() => [
    selectedRepoWindowsRootProvider.overrideWithValue(root),
    directoryListingProvider.overrideWith(
      (ref, dir) async => listings[dir] ?? const [],
    ),
    revealInFileManagerProvider.overrideWithValue(
      RevealInFileManager(
        host: FakeCommandRunner(),
        translator: const PathTranslator(),
        environmentFor: (_) => null,
        fileManagerOverride: HostFileManager.windowsExplorer,
      ),
    ),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: panelOverrides(),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context);
                  return const FileExplorerView();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void reveal({bool isDirectory = false, String path = target}) => container
      .read(fileRevealTargetProvider.notifier)
      .reveal(FileRevealTarget(hostPath: path, isDirectory: isDirectory));

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

    // Two folders opened, each waiting on its own listing before the next
    // could be asked for.
    expect(find.text('src'), findsOneWidget);
    expect(find.text('app.dart'), findsOneWidget);
    expect(rowColour(tester, 'app.dart'), isNotNull);
    // Selected, not opened: nothing was handed to an editor.
    expect(find.text('Opening in editor…'), findsNothing);
    // ...and the rows beside the path down are not selected.
    expect(rowColour(tester, 'main.dart'), isNull);
    expect(rowColour(tester, 'pubspec.yaml'), isNull);
  });

  testWidgets('a target that arrived while the panel was closed is honoured '
      'when it opens', (tester) async {
    final closed = ProviderContainer(overrides: panelOverrides());
    addTearDown(closed.dispose);
    // Nothing of the panel exists yet — this is a path clicked with Files not
    // on screen.
    closed
        .read(fileRevealTargetProvider.notifier)
        .reveal(const FileRevealTarget(hostPath: target, isDirectory: false));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: closed,
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
    // Open the whole tree by hand first, so what is counted below is the cost
    // of the *target arriving*, not the cost of listing folders.
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('app.dart'), findsOneWidget);

    debugFileRowBuilds = 0;
    reveal();
    await tester.pumpAndSettle();

    // Twenty-five rows are on screen and three are redrawn: the two folders on
    // the way and the leaf. The tree is one flat list, so a folder no longer
    // rebuilds its children, and every other row's `select` saw no change.
    expect(debugFileRowBuilds, 3);
  });

  testWidgets('clearing the target lets go of the selection', (tester) async {
    await pump(tester);
    reveal();
    await tester.pumpAndSettle();

    container.read(fileRevealTargetProvider.notifier).clear();
    await tester.pumpAndSettle();

    // The tree stays where the reader left it — folders opened are theirs now —
    // but nothing is highlighted.
    expect(find.text('app.dart'), findsOneWidget);
    expect(rowColour(tester, 'app.dart'), isNull);
  });
}
