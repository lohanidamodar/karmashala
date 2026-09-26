import 'package:karmashala_ui/icons.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/environment_health.dart';
import 'package:karmashala/src/features/environments/application/system_health.dart';
import 'package:karmashala/src/features/environments/application/system_health_service.dart';
import 'package:karmashala/src/features/environments/presentation/environment_health_dialog.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/system_health_fakes.dart';

/// What the panel is allowed to say, and when.
///
/// It replaces a panel that said "Tools available — the MCP bridge is
/// installed" for over an hour on 2026-09-03 while nothing worked. The cases
/// here are the two ways that happens: claiming health that was never
/// measured, and showing a measurement without saying how old it is.
void main() {
  final now = DateTime.utc(2026, 9, 3, 14);

  Future<void> pump(WidgetTester tester, SystemHealthReport report) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWithValue(FixedClock(now)),
          systemHealthProvider.overrideWith(
            () => FixedSystemHealthController(report),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: EnvironmentHealthDialog()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('before anything is checked it claims nothing', (tester) async {
    await pump(tester, SystemHealthReport.notChecked);

    expect(find.text('System health'), findsOneWidget);
    expect(find.textContaining('Nothing has been checked yet'), findsOneWidget);
    expect(
      find.textContaining('nothing is known about this machine yet'),
      findsOneWidget,
    );
    // The button offers to look; it does not report.
    expect(find.text('Check now'), findsOneWidget);
    expect(find.text('Check again'), findsNothing);
  });

  testWidgets('a reading is shown with its age', (tester) async {
    await pump(
      tester,
      SystemHealthReport(
        // Two hours old. Without the age beside it this row would read as a
        // live statement about the machine, which is exactly the failure.
        checkedAt: now.subtract(const Duration(hours: 2)),
        checks: const [
          SystemCheck(
            id: SystemCheckId.mcpBridge,
            title: 'MCP bridge',
            level: HealthLevel.healthy,
            summary: 'Answering — the bridge started and finished a handshake.',
            took: Duration(milliseconds: 118),
          ),
        ],
        environments: [],
      ),
    );

    expect(find.textContaining('Checked 2h ago'), findsOneWidget);
    expect(find.textContaining('Nothing here is re-checked'), findsOneWidget);
    // What the reading cost, so re-running it is an informed choice.
    expect(find.text('118 ms'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
  });

  testWidgets('a failing check carries the line that fixes it', (tester) async {
    await pump(
      tester,
      SystemHealthReport(
        checkedAt: now,
        checks: const [
          SystemCheck(
            id: SystemCheckId.wslInterop,
            title: 'WSL → Windows interop (archlinux)',
            level: HealthLevel.failed,
            summary:
                'Gone — no interop handler is registered, so every Windows '
                'program a session here spawns fails with ENOEXEC.',
            remedy: 'This is the machine, not the app.',
            remedyCommand: kWslInteropRepairCommand,
            took: Duration(milliseconds: 402),
          ),
        ],
        environments: [],
      ),
    );

    expect(find.text('WSL → Windows interop (archlinux)'), findsOneWidget);
    expect(find.textContaining('fails with ENOEXEC'), findsOneWidget);
    // A verdict nobody can act on is half a feature.
    expect(find.text(kWslInteropRepairCommand), findsOneWidget);
    expect(find.byIcon(AppIcons.copySimple), findsOneWidget);
    expect(find.byIcon(AppIcons.xCircle), findsOneWidget);
  });

  testWidgets('"not checked" is drawn as its own state', (tester) async {
    await pump(
      tester,
      SystemHealthReport(
        checkedAt: now,
        checks: const [
          SystemCheck.notChecked(
            id: SystemCheckId.androidTooling,
            title: 'Android tooling',
            reason: 'No Android SDK on this host, so nothing was checked.',
          ),
        ],
        environments: [],
      ),
    );

    // Not the failure mark and not the tick: its own icon, so a row nobody
    // measured cannot be mistaken for either.
    expect(find.byIcon(AppIcons.question), findsOneWidget);
    expect(find.byIcon(AppIcons.checkCircle), findsOneWidget); // the title only
    expect(find.byIcon(AppIcons.xCircle), findsNothing);
  });

  testWidgets('an environment row names the agent versions', (tester) async {
    await pump(
      tester,
      SystemHealthReport(
        checkedAt: now,
        checks: const [],
        environments: [
          EnvironmentHealth(
            environment: windowsEnv(),
            level: HealthLevel.healthy,
            summary: '1 coding agent ready.',
            gitVersion: 'git version 2.51.0.windows.1',
            installations: [
              AgentInstallation(
                id: 'a1',
                agentId: 'claude',
                executable: const EnvironmentPath(
                  environmentId: 'windows',
                  path: r'C:\claude.cmd',
                ),
                version: '2.1.251',
                createdAt: testTime,
              ),
            ],
          ),
        ],
      ),
    );

    // Which version is installed decides which modes a session there can use,
    // so the version is part of the row rather than the name alone.
    expect(
      find.textContaining('git version 2.51.0.windows.1 · claude 2.1.251'),
      findsOneWidget,
    );
  });
}
