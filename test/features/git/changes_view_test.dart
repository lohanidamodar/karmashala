import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/git/domain/file_change.dart';
import 'package:chitragupta/src/features/git/presentation/changes_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required List<FileChange> files}) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryChangesProvider.overrideWith((ref) async => files),
          fileDiffByPathProvider(
            'lib/main.dart',
          ).overrideWith((ref) async => '@@ -1 +1 @@\n-old line\n+new line\n'),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
  }

  testWidgets('lists changed files and expands one to show its diff inline', (
    tester,
  ) async {
    await pump(
      tester,
      files: const [
        FileChange(
          path: 'lib/main.dart',
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
      ],
    );
    await tester.pumpAndSettle();

    // Collapsed by default: the file is listed, the diff is not shown yet.
    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(find.text('+new line'), findsNothing);

    // Expanding the file reveals its diff inline.
    await tester.tap(find.text('lib/main.dart'));
    await tester.pumpAndSettle();

    expect(find.text('+new line'), findsOneWidget);
    expect(find.text('-old line'), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no changes', (tester) async {
    await pump(tester, files: const []);
    await tester.pumpAndSettle();
    expect(find.text('No working-tree changes.'), findsOneWidget);
  });
}
