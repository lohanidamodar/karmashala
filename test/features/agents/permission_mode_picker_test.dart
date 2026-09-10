import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/presentation/permission_mode_picker.dart';

void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode);
  final codex = AgentRegistry.builtIn.byId(AgentIds.codex);
  PermissionSelection? picked;

  Future<void> pump(
    WidgetTester tester, {
    required dynamic descriptor,
    PermissionSelection? selection,
  }) async {
    picked = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PermissionModePicker(
              descriptor: descriptor,
              selection:
                  selection ?? descriptor.launch.permission.defaultSelection,
              onChanged: (s) => picked = s,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the selected mode and hands back the one picked', (
    tester,
  ) async {
    await pump(tester, descriptor: claude);
    expect(find.text('Ask'), findsOneWidget);

    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan mode'));
    await tester.pumpAndSettle();

    // The whole selection comes back, not just the changed axis, so no caller
    // has to merge one itself.
    expect(picked, const PermissionSelection({'mode': 'plan'}));
  });

  testWidgets('offers all six of Claude Code\'s modes, none disabled', (
    tester,
  ) async {
    // The point of the change: three of these could not be expressed at all
    // under the shared enum, and none of them needs a disabled row now,
    // because every row is one of the CLI's own modes.
    await pump(tester, descriptor: claude);
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();

    // Each row is the CLI's own word, with the rung's familiar name in front
    // of it where that reads better. "Plan mode" keeps its own name — Claude
    // Code already says the word — and the bypass rung was left alone.
    for (final label in [
      'Plan mode',
      "Plan · Don't ask",
      'Ask every time',
      'Build · Accept edits',
      'Build · Automatic',
      'Bypass (full autonomy)',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(
      tester
          .widgetList<DesktopMenuDetailItem<PermissionAxisChoice>>(
            find.byType(DesktopMenuDetailItem<PermissionAxisChoice>),
          )
          .every((item) => item.enabled),
      isTrue,
    );
  });

  testWidgets('Codex draws two labelled groups, not one flat list', (
    tester,
  ) async {
    // A sandbox and an approval policy are separate questions, and the request
    // that produced this control was explicitly that they not be flattened.
    await pump(tester, descriptor: codex);
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();

    expect(find.text('SANDBOX'), findsOneWidget);
    expect(find.text('APPROVAL POLICY'), findsOneWidget);
    // Codex spells the read-only rung as a sandbox, which is where the
    // borrowed name earns its place; its approval values are all the bypass
    // rung, which has none.
    expect(find.text('Plan · Read-only'), findsOneWidget);
    expect(find.text('Never ask'), findsOneWidget);
  });

  testWidgets('a superseded axis is listed, disabled, and says why', (
    tester,
  ) async {
    // The disabled-with-a-reason affordance, doing its remaining real job:
    // Codex's bypass flag replaces the approval policy, so those rows are
    // shown with the reason rather than hidden.
    await pump(
      tester,
      descriptor: codex,
      selection: const PermissionSelection({
        'sandbox': 'bypass-all',
        'approval': 'on-request',
      }),
    );
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();

    expect(find.textContaining('nothing set here is passed'), findsWidgets);
    final approvalRow = tester.widget<DesktopMenuDetailItem<PermissionAxisChoice>>(
      find.widgetWithText(DesktopMenuDetailItem<PermissionAxisChoice>, 'Never ask'),
    );
    expect(approvalRow.enabled, isFalse);
  });

  testWidgets('an agent with no established modes says so, in one row', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PermissionModePicker(
              descriptor: null,
              selection: PermissionSelection.empty,
              onChanged: _ignore,
              agentName: 'Mystery CLI',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Not established'), findsOneWidget);

    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    expect(find.text('No permission modes established'), findsOneWidget);
    expect(find.textContaining('Mystery CLI'), findsOneWidget);
  });

  testWidgets('the rows are the house two-line menu row', (tester) async {
    // They were a `Row`/`Column` of their own inside a plain `PopupMenuItem`,
    // beside menus built from `DesktopMenuItem` — a different gutter and
    // Material's own label size.
    await pump(tester, descriptor: claude);
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();

    expect(
      find.byType(DesktopMenuDetailItem<PermissionAxisChoice>),
      findsNWidgets(6),
    );
    // Selected is the checked one, and only it. (The chip's own face carries a
    // check too, so the search is confined to the menu.)
    expect(
      find.descendant(
        of: find.byType(DesktopMenuDetailItem<PermissionAxisChoice>),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(
            find.widgetWithText(
              DesktopMenuDetailItem<PermissionAxisChoice>,
              'Bypass (full autonomy)',
            ),
          )
          .height,
      greaterThanOrEqualTo(Chrome.menuRowTall),
    );
  });
}

void _ignore(PermissionSelection _) {}
