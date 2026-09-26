import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/decision_record_panel.dart';

import '../../support/window_matrix.dart';

/// "Record a decision" is a three-field form; at the minimum window with large
/// text it has to scroll rather than push its fields and buttons off screen.
void main() {
  testWidgets('the record-a-decision dialog survives the window matrix', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      because: 'a form opened over a session to record a constraint',
      build: () => ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => recordDecisionDialog(context, ref, 's1'),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
      warmUp: (tester) async {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      },
    );
  });
}
