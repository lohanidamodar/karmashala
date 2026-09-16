import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/fanout/presentation/fanout_usage_strip.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The fan-out strip's bar is the shared meter: status colours rather than the
/// accent, and a tick where an even rate through the window would be.
void main() {
  testWidgets('a comfortable account is drawn healthy, not in the accent, '
      'with its pace tick', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          agentUsageProvider.overrideWith(
            (ref, install) async => AgentUsage(
              fetchedAt: testTime,
              windows: [
                UsageWindow(
                  label: '5-hour',
                  percent: install.agentId == AgentIds.codex ? 97 : 12,
                  resetsAt: testTime.add(const Duration(hours: 4)),
                  span: kUsageFiveHourWindow,
                ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FanOutUsageStrip(
              installations: [
                agentInstallation(id: 'a1', agentId: AgentIds.claudeCode),
                agentInstallation(id: 'a2', agentId: AgentIds.codex),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final meters = tester.widgetList<LinearMeter>(find.byType(LinearMeter));
    final semantic = SemanticColors.forBrightness(Brightness.light);
    expect(meters.map((m) => m.color), [semantic.idle, semantic.failure]);
    for (final meter in meters) {
      expect(meter.marker, closeTo(0.2, 1e-9), reason: '1h of a 5h window');
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
