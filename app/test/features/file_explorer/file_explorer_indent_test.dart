import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';

import 'explorer_fixture.dart';

/// The tree's indentation, measured rather than read off the source: a row
/// and the "Empty"/"Loading…" placeholder share one token.
void main() {
  const root = r'C:\src\app';

  Future<void> pump(WidgetTester tester, {bool emptyLib = false}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: explorerOverrides(root, {
          root: [dirEntry(r'C:\src\app\lib')],
          if (!emptyLib) r'C:\src\app\lib': [fileEntry(r'C:\src\app\lib\a.dart')],
        }),
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

    expect(tester.getTopLeft(find.text('a.dart')).dx - top, Chrome.treeIndent);
  });

  testWidgets('the top level sits at the panel\'s own inset', (tester) async {
    await pump(tester);
    final padding = tester.widget<Padding>(
      find.ancestor(of: find.text('lib'), matching: find.byType(Padding)).first,
    );
    expect((padding.padding as EdgeInsets).left, Insets.md);
  });

  testWidgets('a placeholder is indented by the gutter as well', (
    tester,
  ) async {
    await pump(tester, emptyLib: true);
    final panel = tester.getTopLeft(find.byType(FileExplorerView)).dx;

    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Empty')).dx - panel,
      Insets.md + Chrome.treeIndent + Chrome.treeGutter,
    );
  });
}
