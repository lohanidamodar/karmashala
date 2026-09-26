import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/env_secrets/presentation/env_variable_dialog.dart';

import '../../support/window_matrix.dart';

void main() {
  testWidgets('a refused name keeps the dialog inside the window', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      because: 'the refusal banner is added under a fixed-height form',
      build: () =>
          const ProviderScope(child: MaterialApp(home: EnvVariableDialog())),
      warmUp: (tester) async {
        await tester.enterText(find.byType(TextField).first, 'KARMASHALA_X');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'value');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.textContaining('belong to Karmashala'), findsOneWidget);
      },
    );
  });
}
