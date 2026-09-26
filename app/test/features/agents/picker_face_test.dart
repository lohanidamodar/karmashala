import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/picker_face.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';

/// The one closed face the model and permission menus share — in the composer,
/// the terminal bar, Settings and the continue-with dialog.
void main() {
  Future<void> pump(WidgetTester tester, Widget face, {double width = 400}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: Row(children: [Flexible(child: face)]),
              ),
            ),
          ),
        ),
      );

  Color? colourOf(WidgetTester tester, IconData icon) =>
      tester.widget<Icon>(find.byIcon(icon)).color;

  testWidgets('draws its glyph, name, qualifiers and caret', (tester) async {
    await pump(
      tester,
      const PickerFace(
        icon: AppIcons.robot,
        label: 'Sonnet',
        qualifiers: ['default', 'unlisted'],
      ),
    );
    expect(find.byIcon(AppIcons.robot), findsOneWidget);
    expect(find.text('Sonnet'), findsOneWidget);
    expect(find.text('· default'), findsOneWidget);
    expect(find.text('· unlisted'), findsOneWidget);
    expect(find.byIcon(AppIcons.caretDown), findsOneWidget);
  });

  testWidgets('only an alarming face is tinted', (tester) async {
    final scheme = AppTheme.light().colorScheme;
    await pump(tester, const PickerFace(icon: AppIcons.check, label: 'Ask'));
    expect(colourOf(tester, AppIcons.check), scheme.onSurfaceVariant);

    await pump(
      tester,
      const PickerFace(icon: AppIcons.warning, label: 'Bypass', alarming: true),
    );
    expect(colourOf(tester, AppIcons.warning), scheme.error);
    expect(colourOf(tester, AppIcons.caretDown), scheme.error);
  });

  testWidgets('a cap holds a long name on a wide row', (tester) async {
    await pump(
      tester,
      PickerFace(
        icon: AppIcons.robot,
        label: 'claude-${'x' * 80}',
        maxLabelWidth: 72,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.textContaining('claude-')).width,
      lessThanOrEqualTo(72),
    );
  });

  testWidgets('an unbroken name and its qualifiers give way on a narrow row', (
    tester,
  ) async {
    await pump(
      tester,
      PickerFace(
        icon: AppIcons.check,
        label: 'workspace-write/${'on-request' * 12}',
        qualifiers: const ['default', 'unrecognised'],
      ),
      width: 90,
    );
    expect(tester.takeException(), isNull);
    expect(find.byIcon(AppIcons.caretDown), findsOneWidget);
    expect(
      tester.getSize(find.byType(PickerFace)).width,
      lessThanOrEqualTo(90),
    );
  });
}
