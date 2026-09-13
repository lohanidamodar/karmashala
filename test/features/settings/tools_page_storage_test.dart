import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/presentation/agent_tools_section.dart';

/// **A keyed scroll view and an unkeyed expander share one PageStorage slot.**
///
/// `settings_screen.dart` gives each section's `SingleChildScrollView` a
/// `PageStorageKey`, so the view saves its offset under `['settings-<name>']`.
/// An `ExpansionTile` inside it, with no key of its own, resolves to that same
/// identifier — and on 2026-09-13 one read the saved offset as its expanded
/// flag: *type 'double' is not a subtype of type 'bool?'*, thrown in
/// `initState`, which renders the whole page as nothing.
///
/// Scroll the Tools page, leave it, come back. That is the whole reproduction.
void main() {
  Widget page(PageStorageBucket bucket) => MaterialApp(
    home: PageStorage(
      bucket: bucket,
      child: const Scaffold(
        body: SizedBox(
          height: 300,
          child: SingleChildScrollView(
            key: PageStorageKey<String>('settings-tools'),
            child: AgentToolsSection(),
          ),
        ),
      ),
    ),
  );

  testWidgets('the expanders survive the section being scrolled and rebuilt', (
    tester,
  ) async {
    final bucket = PageStorageBucket();
    await tester.pumpWidget(page(bucket));
    await tester.pumpAndSettle();

    // The offset the scroll view saves under its own key.
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -80));
    await tester.pumpAndSettle();

    // Leaving and coming back: the tiles mount again and read that slot.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(bucket));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'a tile reading a double as its expanded flag throws in '
          'initState, and the page it is on renders nothing at all',
    );
    expect(find.byType(ExpansionTile), findsWidgets);
  });
}
