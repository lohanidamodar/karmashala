import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'pane_group_ui_test.dart'
    show activeTab, controllerOf, pumpWorkbench, workbenchContainer;

/// A split pane's floating handle is invisible until hovered unless its pane
/// is focused — and what cannot be seen must not take a Tab stop either.
void main() {
  testWidgets('an invisible pane handle is not a focus stop', (tester) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    );
    await pumpWorkbench(tester, container);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    expect(activeTab(container).layout.panes, hasLength(2));

    bool focusable(Finder button) => Focus.of(
      tester.element(
        find.descendant(of: button, matching: find.byType(Icon)).first,
      ),
    ).canRequestFocus;

    for (final tooltip in ['Close pane', 'Move pane to a new tab']) {
      final buttons = find.byTooltip(tooltip);
      expect(buttons, findsNWidgets(2), reason: tooltip);
      final stops = [
        for (var i = 0; i < 2; i++)
          if (focusable(buttons.at(i))) i,
      ];
      expect(
        stops,
        hasLength(1),
        reason: 'only the focused pane shows its $tooltip',
      );
    }
  });
}
