import 'package:karmashala_host/mcp_tools.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala/src/features/settings/presentation/agent_tools_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The list of what the agent can actually call.
///
/// Before this the page showed the same 94 names as a wall of chips: complete,
/// and unreadable — nothing said what any of them did, or which ones belonged
/// together. The value here is entirely in the coverage, so it is asserted
/// against the served schemas rather than against a copy of them.
void main() {
  final served = <String>[
    for (final schema in serverToolSchemas) schema['name']! as String,
  ];

  // No ProviderScope, deliberately. The listing is static data compiled into
  // the binary; a `ref.watch` anywhere in it would throw here, which is a
  // cheaper proof that the section costs nothing at idle than any measurement.
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 2400),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: AgentToolsSection())),
      ),
    );
    await tester.pump();
  }

  Future<void> expandEverything(WidgetTester tester) async {
    for (final category in McpToolCategory.values) {
      // Each expansion pushes the families under it down, so the next heading
      // has to be scrolled to before it can be tapped.
      final heading = find.text(category.label);
      await tester.ensureVisible(heading);
      await tester.pumpAndSettle();
      await tester.tap(heading);
      await tester.pumpAndSettle();
    }
  }

  for (final (name, size) in const [
    ('phone', Size(390, 844)),
    ('desktop', Size(1440, 2400)),
  ]) {
    testWidgets('every family is headed and counted at $name width', (
      tester,
    ) async {
      await pump(tester, size: size);
      for (final category in McpToolCategory.values) {
        expect(
          find.text(category.label),
          findsOneWidget,
          reason: '${category.name} is not on the page',
        );
        expect(find.text(category.blurb), findsOneWidget);
        expect(
          find.text('${kMcpToolsByCategory[category]!.length}'),
          findsWidgets,
        );
      }
    });
  }

  testWidgets('a family reads at phone width too', (tester) async {
    // The rows are name-plus-marks over a line of prose, so the marks wrap
    // rather than squeezing the name. An overflow here is a failed test.
    await pump(tester, size: const Size(390, 844));
    final heading = find.text(McpToolCategory.checkpoints.label);
    await tester.ensureVisible(heading);
    await tester.pumpAndSettle();
    await tester.tap(heading);
    await tester.pumpAndSettle();
    expect(find.text('checkpoint_restore'), findsOneWidget);
    expect(find.text('no undo'), findsOneWidget);
  });

  testWidgets('every served tool is listed exactly once, with its line', (
    tester,
  ) async {
    await pump(tester);
    await expandEverything(tester);
    for (final name in served) {
      expect(
        find.text(name),
        findsOneWidget,
        reason: '$name is served and either missing or listed twice',
      );
      expect(
        find.text(kMcpToolListings[name]!.summary),
        findsWidgets,
        reason: '$name has no line beside it',
      );
    }
  });

  testWidgets('the three facts a person acts on are marked', (tester) async {
    await pump(tester);
    await expandEverything(tester);
    // Counted against the table rather than a literal, so a tool that changes
    // its mind about being destructive fails here too.
    final destructive = kMcpToolAnnotations.values.where((a) => a.destructive);
    final readOnly = kMcpToolAnnotations.values.where((a) => a.readOnly);
    final moving = kMcpToolAnnotations.values.where((a) => a.movesAttention);
    expect(find.text('no undo'), findsNWidgets(destructive.length));
    expect(find.text('read-only'), findsNWidgets(readOnly.length));
    expect(find.text('moves attention'), findsNWidgets(moving.length));
  });

  testWidgets('a tool can change nothing and still take the screen', (
    tester,
  ) async {
    // The pair that makes the third mark worth drawing: `browser_pick` wears
    // read-only and moves-attention at once, which no combination of the other
    // two marks could have said.
    await pump(tester);
    final heading = find.text(McpToolCategory.browser.label);
    await tester.ensureVisible(heading);
    await tester.pumpAndSettle();
    await tester.tap(heading);
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text('browser_pick'),
      matching: find.byType(MergeSemantics),
    );
    expect(
      find.descendant(of: row, matching: find.text('read-only')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('moves attention')),
      findsOneWidget,
    );
  });

  testWidgets('the two facts only a client acts on are not', (tester) async {
    // `idempotentHint` answers "is a retry safe", which is a decision a client
    // makes without asking anybody, and `openWorldHint` is already the family
    // heading for every tool that carries it. Both still travel in
    // `tools/list`; neither earns a row of a person's screen.
    await pump(tester);
    await expandEverything(tester);
    expect(find.text('idempotent'), findsNothing);
    expect(find.text('open-world'), findsNothing);
  });

  testWidgets('collapsed, it is a page of headings and not of tools', (
    tester,
  ) async {
    // The whole reason the families collapse: the section sits under three
    // other blocks on the Tools page, and 94 rows unfurled would bury them.
    await pump(tester);
    expect(find.text('device_tap'), findsNothing);
    expect(find.text(McpToolCategory.devices.label), findsOneWidget);
  });
}
