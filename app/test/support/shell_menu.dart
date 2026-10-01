import 'package:flutter_test/flutter_test.dart';

/// Opens the title bar's one menu (the `Menu` glyph) and, in it, [submenu] —
/// `Workspace`, `View` or `Tools`. The bar drew those three as titles of its
/// own until the board's single menu glyph replaced them.
Future<void> openShellMenu(WidgetTester tester, String submenu) async {
  await tester.tap(find.byTooltip('Menu'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(submenu));
  await tester.pumpAndSettle();
}

/// Closes whatever [openShellMenu] opened: the glyph toggles its menu.
Future<void> closeShellMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Menu'));
  await tester.pumpAndSettle();
}
