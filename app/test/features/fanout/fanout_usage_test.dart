import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not part of the main barrel in Riverpod 3.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala/src/features/fanout/presentation/fanout_dialog.dart';
import 'package:karmashala/src/features/fanout/presentation/fanout_usage_strip.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show UsageFailure;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../agents/usage_fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// Usage at the point of decision.
///
/// A fan-out starts several sessions at once; on a nearly exhausted account
/// that turns a considered action into a wasted one. These pin the four states
/// the number can be in — comfortable, nearly exhausted, unknown, still
/// arriving — and, in every one of them, that the launch button is still
/// pressable. That last assertion is the point: this is a warning, never a gate.

/// The compact end of the responsive contract (CLAUDE.md §6).
const phone = WindowCell('390x844 (phone)', Size(390, 844));

/// A usage snapshot with a single window, which is all the strip needs.
AgentUsage windowAt(
  double percent, {
  String label = '5-hour',
  Duration? resetsIn,
}) => AgentUsage(
  windows: [
    UsageWindow(
      label: label,
      percent: percent,
      resetsAt: resetsIn == null ? null : DateTime.now().add(resetsIn),
    ),
  ],
  fetchedAt: testTime,
);

/// The server [seededWorkspace] last stood up, for a test that tells the app
/// the server's usage of an account.
late FakeDataServer workspaceServer;

/// The two installations [seededWorkspace] seeds.
final claudeInstall = agentInstallation(id: 'a1', agentId: AgentIds.claudeCode);
final codexInstall = agentInstallation(
  id: 'a2',
  agentId: AgentIds.codex,
  path: r'C:\Users\me\.bin\codex.exe',
);

/// The workspace the dialog reads — one project with its checkout `r1` — and
/// the two agents installed on this machine.
Future<Override> seededWorkspace() {
  final server = workspaceServer = FakeDataServer()
    ..environmentRows.upsert(windowsEnv())
    ..projectRows.insert(project())
    ..repositoryRows.insert(repository());
  server.installationRows
    ..insert(claudeInstall)
    ..insert(codexInstall);
  return server.override();
}

TestMachine seeded() => TestMachine();

typedef UsageLookup = AsyncValue<AgentUsage> Function(AgentInstallation);

/// Opens the dialog on its setup page and ticks [select] agents, which is what
/// makes the strip ask about anything at all.
///
/// [usageFor] stands in for the account's live usage; without it the strip
/// reads what the server told ([seed] tells it before the dialog opens).
Future<ProviderContainer> pumpSetup(
  WidgetTester tester, {
  UsageLookup? usageFor,
  void Function(FakeDataServer server)? seed,
  int select = 2,
  List<Override> extraOverrides = const [],
}) async {
  seeded();
  final data = await seededWorkspace();
  seed?.call(workspaceServer);
  final container = ProviderContainer(
    overrides: [
      data,
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
      ),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      if (usageFor != null)
        agentUsageProvider.overrideWith((ref, install) => usageFor(install)),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  container.read(selectedRepositoryIdProvider.notifier).select('r1');

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FanOutDialog()),
    ),
  );
  await tester.tap(find.text('New fan-out'));
  await tester.pump();
  for (final agentId in [AgentIds.claudeCode, AgentIds.codex].take(select)) {
    await tick(tester, agentId);
  }
  // Twice: a lookup that resolves in a microtask needs one turn to land and
  // one more frame to be painted.
  await tester.pump();
  await tester.pump();
  return container;
}

/// Ticks one agent's checkbox, scrolling the agent list to it first — in a
/// 720x560 window only the first row or two are on screen.
Future<void> tick(WidgetTester tester, String agentId) async {
  final row = find.widgetWithText(CheckboxListTile, agentId);
  if (row.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      row,
      40,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
  }
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tap(row);
  await tester.pump();
}

/// The launch button, which nothing on this surface may disable.
void expectLaunchStillOffered(WidgetTester tester, {int agents = 2}) {
  final button = tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Launch $agents agents'),
  );
  expect(
    button.onPressed,
    isNotNull,
    reason: 'usage warns; it never blocks the fan-out',
  );
}

void main() {
  testWidgets('a comfortable account shows the number, and no warning', (
    tester,
  ) async {
    // What the server told, through the real providers.
    await pumpSetup(
      tester,
      seed: (server) {
        seedUsage(server, claudeInstall, usage: windowAt(12));
        seedUsage(server, codexInstall, usage: windowAt(12));
      },
    );

    expect(find.text('Starts 2 sessions'), findsOneWidget);
    expect(find.text('Claude Code · Windows · 5-hour'), findsOneWidget);
    expect(find.text('Codex CLI · Windows · 5-hour'), findsOneWidget);
    expect(find.text('12%'), findsNWidgets(2));
    expect(find.textContaining('left on'), findsNothing);
    expectLaunchStillOffered(tester);
  });

  testWidgets('a nearly exhausted account warns, and says what it costs', (
    tester,
  ) async {
    await pumpSetup(
      tester,
      usageFor: (install) => AsyncData(
        install.agentId == AgentIds.claudeCode
            ? windowAt(92, resetsIn: const Duration(hours: 2, minutes: 5))
            : windowAt(12),
      ),
    );

    expect(find.text('Starts 2 sessions'), findsOneWidget);
    expect(
      find.textContaining('Only 8% left on Claude Code · Windows'),
      findsOneWidget,
    );
    // The comparison the user needs: what is left, beside what this spends.
    expect(
      find.textContaining('1 of the 2 sessions runs on it'),
      findsOneWidget,
    );
    expect(find.textContaining('92% · resets in'), findsOneWidget);
    expectLaunchStillOffered(tester);
  });

  testWidgets('a reset is read against the app clock, not the wall clock', (
    tester,
  ) async {
    await pumpSetup(
      tester,
      extraOverrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
      usageFor: (_) => AsyncData(
        AgentUsage(
          windows: [
            UsageWindow(
              label: '5-hour',
              percent: 40,
              resetsAt: testTime.add(const Duration(hours: 3, minutes: 1)),
            ),
          ],
          fetchedAt: testTime,
        ),
      ),
    );

    expect(find.textContaining('40% · resets in 3h'), findsWidgets);
  });

  testWidgets('an unreadable account says so — not 0%, not 100%', (
    tester,
  ) async {
    // The server's failed attempts, in its own words, and no reading ever.
    const notSignedIn = UsageFailure(
      message: 'Not signed in to Claude in this environment.',
      kind: UsageFailureKind.auth,
    );
    final container = await pumpSetup(
      tester,
      seed: (server) {
        seedUsage(server, claudeInstall, failure: notSignedIn);
        seedUsage(server, codexInstall, failure: notSignedIn);
      },
    );

    expect(find.text('not recorded'), findsNWidgets(2));
    expect(
      find.text('Not signed in to Claude in this environment.'),
      findsNWidgets(2),
    );
    // Nothing may be guessed into the gap.
    expect(find.textContaining('%'), findsNothing);

    // The dialog is still a working dialog.
    await tester.enterText(find.byType(TextField), 'do the thing');
    await tester.pump();
    expect(find.text('do the thing'), findsOneWidget);
    expectLaunchStillOffered(tester);

    // Closing the dialog; the container stands in for that here.
    container.dispose();
  });

  testWidgets('a failed lookup over a number we already have keeps the '
      'number', (tester) async {
    // The strip used to read the error first and print "not recorded" over a
    // reading the app was holding — the fan-out is exactly where losing it
    // costs something, because the number is why the dialog shows it at all.
    // The server read the Claude account four minutes ago and has been rate
    // limited since; it never read the Codex one.
    final clock = MovableClock(testTime.add(const Duration(minutes: 4)));
    const rateLimited = UsageFailure(
      message: 'Rate limited by the usage service.',
      kind: UsageFailureKind.rateLimited,
    );
    await pumpSetup(
      tester,
      seed: (server) {
        seedUsage(
          server,
          claudeInstall,
          usage: usageSnapshot(percent: 62),
          failure: rateLimited,
        );
        seedUsage(server, codexInstall, failure: rateLimited);
      },
      extraOverrides: [clockProvider.overrideWithValue(clock)],
    );

    expect(find.textContaining('62%'), findsOneWidget);
    expect(find.text('Last checked 4m ago · Rate limited'), findsOneWidget);
    expect(
      find.text('not recorded'),
      findsOneWidget,
      reason: 'the Codex account has no reading at all, and still says so',
    );
    expectLaunchStillOffered(tester);
  });

  testWidgets('an account with no windows reported is not recorded either', (
    tester,
  ) async {
    await pumpSetup(
      tester,
      usageFor: (_) =>
          AsyncData(AgentUsage(windows: const [], fetchedAt: testTime)),
    );

    expect(find.text('not recorded'), findsNWidgets(2));
    expect(find.text('No usage windows reported.'), findsNWidgets(2));
    expectLaunchStillOffered(tester);
  });

  testWidgets('an account that names tiers and no quota is not recorded '
      'either', (tester) async {
    // Antigravity. A reply arrived, it named what the account is allowed, and
    // it measured nothing — which at the point of spending several sessions at
    // once must read as "unknown" and never as an untouched 0%.
    await pumpSetup(tester, usageFor: (_) => AsyncData(antigravitySnapshot()));

    expect(find.text('not recorded'), findsNWidgets(2));
    expect(find.text('No quota reported for this account.'), findsNWidgets(2));
    expect(find.textContaining('%'), findsNothing);
    expectLaunchStillOffered(tester);
  });

  testWidgets('a reading not yet taken never holds the dialog up', (
    tester,
  ) async {
    // The server has said nothing of either account yet.
    await pumpSetup(tester);

    // Nothing has arrived, and the dialog is fully usable anyway.
    expect(find.text('checking…'), findsNWidgets(2));
    await tester.enterText(find.byType(TextField), 'do the thing');
    await tester.pump();
    expect(find.text('do the thing'), findsOneWidget);
    expectLaunchStillOffered(tester);

    // The server's readings arrive, told as changes.
    seedUsage(workspaceServer, claudeInstall, usage: windowAt(12));
    seedUsage(workspaceServer, codexInstall, usage: windowAt(12));
    await tester.pump();
    await tester.pump();
    expect(find.text('12%'), findsNWidgets(2));
    expectLaunchStillOffered(tester);
  });

  testWidgets('nothing is asked about an account this fan-out will not spend', (
    tester,
  ) async {
    final asked = <String>[];
    await pumpSetup(
      tester,
      select: 0,
      usageFor: (install) {
        asked.add(install.id);
        return AsyncData(windowAt(12));
      },
    );

    expect(asked, isEmpty);
    expect(find.textContaining('Starts'), findsNothing);

    await tick(tester, AgentIds.claudeCode);
    expect(asked, ['a1']);
    expect(find.text('Starts 1 session'), findsOneWidget);
  });

  testWidgets('the strip survives the window matrix, warning and all', (
    tester,
  ) async {
    seeded();
    final container = ProviderContainer(
      overrides: [
        await seededWorkspace(),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        agentUsageProvider.overrideWith(
          (ref, install) => AsyncData(
            install.agentId == AgentIds.claudeCode
                ? windowAt(92, resetsIn: const Duration(hours: 2, minutes: 5))
                : windowAt(12),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');

    await expectSurvivesWindowMatrix(
      tester,
      build: () => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: FanOutDialog(),
          debugShowCheckedModeBanner: false,
        ),
      ),
      warmUp: (tester) async {
        await tester.tap(find.text('New fan-out'));
        await tester.pump();
        await tick(tester, AgentIds.claudeCode);
        await tick(tester, AgentIds.codex);
      },
      because:
          'the usage strip is one more block inside a dialog that already '
          'asks for more than the 720x560 window',
    );
  });

  testWidgets('the strip itself reads from a phone width to a desktop one', (
    tester,
  ) async {
    // The dialog's own matrix stops at the 720x560 minimum window, because its
    // first page (the comparison list header) has never fitted 390 and that is
    // not this change. The block added here is measured on its own, from the
    // compact width CLAUDE.md asks for up to the desktop one — three accounts,
    // one of them warning and one of them unreadable, which is the tallest and
    // wordiest the strip ever gets.
    seeded();
    final container = ProviderContainer(
      overrides: [
        await seededWorkspace(),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        agentUsageProvider.overrideWith(
          (ref, install) => switch (install.agentId) {
            AgentIds.claudeCode => AsyncData(
              windowAt(96, resetsIn: const Duration(hours: 2, minutes: 5)),
            ),
            AgentIds.codex => AsyncData(windowAt(12, label: '7-day')),
            _ => AsyncError(
              UsageException('Usage is not available for Antigravity.'),
              StackTrace.empty,
            ),
          },
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: FanOutUsageStrip(
                installations: [
                  agentInstallation(id: 'a1', agentId: AgentIds.claudeCode),
                  agentInstallation(id: 'a2', agentId: AgentIds.codex),
                  agentInstallation(id: 'a3', agentId: AgentIds.antigravity),
                ],
              ),
            ),
          ),
        ),
      ),
      matrix: const [phone, ...windowMatrix],
      // The strip is a readout: it has no controls to tab to or to name.
      checkFocus: false,
      checkSemantics: false,
      because: 'a usage row must not clip the account it names',
    );
    container.dispose();
  });
}
