import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala_store/database.dart';

import '../../support/window_matrix.dart';
import 'permission_mode_chip_test.dart' show harness, startAgent;

/// The bypass confirmation names three consequences; every one of them, and
/// both buttons, must be reachable at the minimum window and at large text.
void main() {
  testWidgets('the bypass confirmation survives the window matrix', (
    tester,
  ) async {
    // One harness per window: `build` is synchronous, and a harness is not.
    final prepared = [
      for (var i = 0; i < windowMatrix.length; i++)
        await harness(
          agentId: AgentIds.claudeCode,
          mode: 'mode=manual',
          externalSessionId: 'ext-1',
        ),
    ];
    final databases = <AppDatabase>[];
    addTearDown(() {
      for (final h in prepared) {
        h.db.close();
      }
    });
    await expectSurvivesWindowMatrix(
      tester,
      because: 'a warning that restarts a running session',
      build: () {
        final h = prepared[databases.length];
        databases.add(h.db);
        return h.app;
      },
      warmUp: (tester) async {
        startAgent(tester, databases.last);
        await tester.tap(find.byType(PermissionModeChip));
        await tester.pumpAndSettle();
        // The menu scrolls at large text; the dialog is what is measured.
        await tester.ensureVisible(find.text('Bypass (full autonomy)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bypass (full autonomy)'));
        await tester.pumpAndSettle();
        expect(find.text('Bypass (full autonomy)?'), findsOneWidget);
      },
    );
  });
}
