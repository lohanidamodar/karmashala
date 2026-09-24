import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';

class _Editing extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String? path) => state = path;
}

final _editing = NotifierProvider<_Editing, String?>(_Editing.new);

/// The Files panel follows the file being edited, while it is open.
void main() {
  const root = '/src/app';

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        selectedRepoWindowsRootProvider.overrideWithValue(root),
        directoryListingProvider.overrideWith(
          (ref, dir) async => switch (dir) {
            root => const [
              DirEntry(
                name: 'lib',
                isDirectory: true,
                windowsPath: '$root/lib',
              ),
            ],
            '$root/lib' => const [
              DirEntry(
                name: 'main.dart',
                isDirectory: false,
                windowsPath: '$root/lib/main.dart',
              ),
            ],
            _ => const [],
          },
        ),
        activeEditorHostPathProvider.overrideWith((ref) => ref.watch(_editing)),
      ],
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
    c.read(_editing.notifier).open('$root/lib/main.dart');
    await tester.pumpAndSettle();

    expect(c.read(fileRevealTargetProvider)?.hostPath, '$root/lib/main.dart');
    // The folder on the way was opened, so the file's row is drawn.
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('a file elsewhere moves nothing', (tester) async {
    final c = await pump(tester);
    c.read(_editing.notifier).open('/elsewhere/notes.md');
    await tester.pumpAndSettle();

    expect(c.read(fileRevealTargetProvider), isNull);
  });

  testWidgets('a file already being edited is found when the panel opens', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        selectedRepoWindowsRootProvider.overrideWithValue(root),
        directoryListingProvider.overrideWith((ref, dir) async => const []),
        activeEditorHostPathProvider.overrideWithValue('$root/lib/main.dart'),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FileExplorerView())),
      ),
    );
    await tester.pump();

    expect(
      container.read(fileRevealTargetProvider)?.hostPath,
      '$root/lib/main.dart',
    );
  });
}
