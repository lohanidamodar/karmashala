import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/read.dart' show SessionMediaItem, SessionMediaOrigin;
import 'package:karmashala/src/features/media/presentation/session_image_dialog.dart';
import 'package:karmashala_ui/dialogs.dart';

void main() {
  testWidgets('the header is the house dialog title, and it closes', (
    tester,
  ) async {
    final at = DateTime.utc(2026, 9, 16, 8);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SessionImageDialog(
                reference: '[Image #6]',
                now: at.add(const Duration(hours: 4)),
                item: SessionMediaItem(
                  id: 'm1',
                  origin: SessionMediaOrigin.values.first,
                  sequence: 1,
                  at: at,
                  problem: 'The copy is gone.',
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final title = tester.widget<DesktopDialogTitle>(
      find.byType(DesktopDialogTitle),
    );
    expect(title.title, '[Image #6]');
    expect(title.subtitle, contains('4h ago'));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionImageDialog), findsNothing);
  });
}
