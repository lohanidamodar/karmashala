import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_options.dart';
import 'package:karmashala/src/features/agents/presentation/permission_mode_picker.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Expresses two of the three modes, which is the shape that makes the
/// selectable rule visible.
const _forker = AgentDescriptor(
  id: 'forker',
  displayName: 'Forker CLI',
  binaries: AgentBinaries(windows: ['f'], posix: ['f']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
      PermissionMode.bypass: PermissionModeMapping.exact(['--trust-me']),
    },
  ),
);

void main() {
  PermissionMode? picked;

  Future<void> pump(
    WidgetTester tester, {
    PermissionMode selected = PermissionMode.ask,
  }) async {
    picked = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PermissionModePicker(
              options: permissionOptionsFor(_forker),
              selected: selected,
              onChanged: (mode) => picked = mode,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the selected mode and hands back the one picked', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Ask'), findsOneWidget);

    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bypass (full autonomy)'));
    await tester.pumpAndSettle();

    expect(picked, PermissionMode.bypass);
  });

  testWidgets('a mode the agent cannot be told is listed, not selectable', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();

    // Loop 31 §4 option C: shown with the reason rather than hidden, so the
    // user is not left hunting for the mode that went missing.
    expect(find.text('Accept edits'), findsOneWidget);
    expect(find.textContaining('takes no flag for this'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuItem<PermissionMode>>(
            find.widgetWithText(PopupMenuItem<PermissionMode>, 'Accept edits'),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets('a selection the agent cannot express is flagged, not hidden', (
    tester,
  ) async {
    // The state a carried mode lands in when the target has no equivalent:
    // nothing is passed and the agent's own default applies, and the control
    // has to say that rather than quietly showing a mode that is not in force.
    await pump(tester, selected: PermissionMode.acceptEdits);
    expect(find.text('Accept edits'), findsOneWidget);
    expect(find.text('· not enforced'), findsOneWidget);
  });
}
