import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/widgets/desktop_menu.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_model_options.dart';
import 'package:karmashala/src/features/agents/presentation/model_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Takes `--model`, so every row is one the CLI can actually be told.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    model: AgentModelSupport.atLaunchOnly(
      flag: '--model',
      models: [
        AgentModel(id: 'fast', label: 'Fast', summary: 'Quick work.'),
        AgentModel(id: 'deep', label: 'Deep', summary: 'Hard work.'),
      ],
      evidence: 'invented for this test',
    ),
  ),
);

/// Its models are known and there is no way to ask for one — the shape that
/// makes the selectable rule visible.
const _untellable = AgentDescriptor(
  id: 'untellable',
  displayName: 'Untellable CLI',
  binaries: AgentBinaries(windows: ['u'], posix: ['u']),
  launch: AgentLaunchSpec(
    model: AgentModelSupport.listedOnly(
      models: [AgentModel(id: 'big', label: 'Big', summary: 'The big one.')],
      evidence: 'invented for this test',
    ),
  ),
);

void main() {
  ModelChoice? picked;

  Future<void> pump(
    WidgetTester tester, {
    AgentDescriptor descriptor = _rover,
    String? selected,
  }) async {
    picked = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ModelPicker(
              options: modelOptionsFor(descriptor),
              selected: selected,
              onChanged: (choice) => picked = choice,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('naming no model is the shipped state and a row of its own', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Let the agent choose'), findsOneWidget);

    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();

    // The trap `ModelChoice` documents: a null menu value reads as a dismissal
    // and never reaches `onSelected`. The row's value is a `ModelChoice`
    // holding null, which is a value like any other.
    final first = tester
        .widgetList<DesktopMenuDetailItem<ModelChoice>>(
          find.byType(DesktopMenuDetailItem<ModelChoice>),
        )
        .first;
    expect(first.value, ModelChoice.followDefault);
    expect(first.enabled, isTrue);
    expect(find.byType(DesktopMenuDivider), findsOneWidget);
    // Checked, and the only checked row: nothing is selected but this.
    expect(
      find.descendant(
        of: find.byType(DesktopMenuDetailItem<ModelChoice>),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(
          DesktopMenuDetailItem<ModelChoice>,
          'Let the agent choose',
        ),
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('picking a model hands it back, and the way out is selectable', (
    tester,
  ) async {
    await pump(tester, selected: 'fast');
    expect(find.text('Fast'), findsOneWidget);

    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deep'));
    await tester.pumpAndSettle();
    expect(picked?.modelId, 'deep');

    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Let the agent choose'));
    await tester.pumpAndSettle();
    // Null arrives as a value, which is the whole point of the wrapper.
    expect(picked, ModelChoice.followDefault);
    expect(picked?.modelId, isNull);
  });

  testWidgets('a model the agent cannot be told is listed, not selectable', (
    tester,
  ) async {
    await pump(tester, descriptor: _untellable);
    await tester.tap(find.byType(ModelPicker));
    await tester.pumpAndSettle();

    // Shown with the reason rather than hidden, so the user is not left hunting
    // for the model that went missing.
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('not settable'), findsOneWidget);
    expect(find.textContaining('takes no model flag'), findsOneWidget);
    expect(
      tester
          .widget<DesktopMenuDetailItem<ModelChoice>>(
            find.widgetWithText(DesktopMenuDetailItem<ModelChoice>, 'Big'),
          )
          .enabled,
      isFalse,
    );
    // And the way out is still open: naming no model always works.
    expect(
      tester
          .widgetList<DesktopMenuDetailItem<ModelChoice>>(
            find.byType(DesktopMenuDetailItem<ModelChoice>),
          )
          .first
          .enabled,
      isTrue,
    );
  });

  testWidgets('a selection the agent cannot express is flagged, not hidden', (
    tester,
  ) async {
    await pump(tester, descriptor: _untellable, selected: 'big');

    expect(find.text('Big'), findsOneWidget);
    expect(find.text('· not settable'), findsOneWidget);
    expect(find.byIcon(AppIcons.warningCircle), findsOneWidget);
  });

  testWidgets('the reason is available without opening the menu', (
    tester,
  ) async {
    // What a settings card puts above the control, read off the same rows the
    // menu draws so the two cannot word it differently.
    expect(modelNotSettableReason(_rover), isNull);
    expect(
      modelNotSettableReason(_untellable),
      contains('takes no model flag'),
    );
    expect(modelNotSettableReason(null), isNull);
  });
}
