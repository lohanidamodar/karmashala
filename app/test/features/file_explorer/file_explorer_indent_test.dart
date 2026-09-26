import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';

import '../../support/fake_command_runner.dart';

/// The tree's indentation, measured rather than read off the source.
///
/// It used to be `12.0 + depth * 14` written twice — once for a row and once
/// for the "Empty"/"Loading…" placeholder — with nothing tying the two
/// together and no token either could be checked against.
void main() {
  const root = r'C:\src\app';
  const lib = DirEntry(
    name: 'lib',
    isDirectory: true,
    windowsPath: r'C:\src\app\lib',
  );
  const nested = DirEntry(
    name: 'main.dart',
    isDirectory: false,
    windowsPath: r'C:\src\app\lib\main.dart',
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedRepoWindowsRootProvider.overrideWithValue(root),
          activeEditorHostPathProvider.overrideWithValue(null),
          // The rows build a context menu, which asks whether the host could
          // reveal the path; without this the question reaches the database.
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: FakeCommandRunner(),
              translator: const PathTranslator(),
              environmentFor: (id) => null,
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
          directoryListingProvider.overrideWith(
            (ref, dir) async => switch (dir) {
              root => const [lib],
              r'C:\src\app\lib' => const [nested],
              _ => const <DirEntry>[],
            },
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SizedBox(width: 320, child: FileExplorerView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one level in is exactly Chrome.treeIndent further in', (
    tester,
  ) async {
    await pump(tester);
    final top = tester.getTopLeft(find.text('lib')).dx;

    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();

    final child = tester.getTopLeft(find.text('main.dart')).dx;
    expect(child - top, Chrome.treeIndent);
  });

  testWidgets('the top level sits at the panel\'s own inset', (tester) async {
    await pump(tester);
    // Depth zero is `Insets.md` — the same inset the panel's header uses, so
    // the tree lines up with the word "Files" above it rather than with a
    // number of its own.
    final padding = tester.widget<Padding>(
      find.ancestor(of: find.text('lib'), matching: find.byType(Padding)).first,
    );
    expect((padding.padding as EdgeInsets).left, Insets.md);
  });

  testWidgets('a placeholder is indented by the gutter as well', (
    tester,
  ) async {
    // "Empty" belongs to the level it is reporting on, so it clears the
    // disclosure column instead of starting a new one.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedRepoWindowsRootProvider.overrideWithValue(root),
          activeEditorHostPathProvider.overrideWithValue(null),
          // The rows build a context menu, which asks whether the host could
          // reveal the path; without this the question reaches the database.
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: FakeCommandRunner(),
              translator: const PathTranslator(),
              environmentFor: (id) => null,
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
          directoryListingProvider.overrideWith(
            (ref, dir) async => dir == root ? const [lib] : const <DirEntry>[],
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SizedBox(width: 320, child: FileExplorerView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final panel = tester.getTopLeft(find.byType(FileExplorerView)).dx;

    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Empty')).dx - panel,
      Insets.md + Chrome.treeIndent + Chrome.treeGutter,
    );
  });
}
