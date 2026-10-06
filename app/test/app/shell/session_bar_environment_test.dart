import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/explorer/presentation/environment_rows.dart';
import 'package:karmashala/src/features/remote/application/machines_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The session bar says where the session runs**, beside its agent's mark:
/// the environment's glyph, its name where there is room, and on hover the
/// full name and the working folder. The same names the sidebar uses.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;

  const barKey = ValueKey('session-bar-environment');
  const folder = r'C:\src\demo\app';

  Future<void> setUpWith({List<Override> extra = const []}) async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:archlinux', distro: 'archlinux'));
    server.projectRows.insert(project());
    server.repositoryRows
      ..insert(repository())
      ..insert(
        repository(
          id: 'r-wsl',
          environmentId: 'wsl:archlinux',
          path: '/home/me/demo',
        ),
      );
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        sessionContinuationProvider.overrideWith(
          (ref, _) => SessionContinuation(
            targets: const [],
            plan: SessionForkPlan.decide(descriptor: null, agentName: 'ACP'),
          ),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeAcp,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.none,
            ),
          ),
        ),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
  }

  void seedChatSession({String repositoryId = 'r1'}) =>
      db.server.sessionRows.insert(
        Session(
          id: 'acp-1',
          repositoryId: repositoryId,
          agentInstallationId: 'acp',
          title: 'Over ACP',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
        ),
      );

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool compact = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const workbench = WorkbenchView();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: compact
                ? const CompactWorkbenchScope(child: workbench)
                : workbench,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inMark(Finder matching) =>
      find.descendant(of: find.byKey(barKey), matching: matching);

  /// The machine's name as the bar draws it: in the mark, or — on the one
  /// status line — just after it, where it yields before the facts.
  Finder label(String text) => find.descendant(
    of: find.byWidgetPredicate(
      (w) =>
          w.key == barKey ||
          w.key == const ValueKey('session-bar-environment-label'),
    ),
    matching: find.text(text),
  );

  for (final (name, size, compact, labelled) in [
    ('one status line', const Size(1440, 900), false, true),
    ('facts over controls', const Size(700, 900), false, true),
    ('a split-narrow bar', const Size(500, 900), false, false),
    ('phone', const Size(390, 844), true, false),
  ]) {
    testWidgets('$name: the bar names where the session runs '
        '${labelled ? 'with its name' : 'by its glyph alone'}', (tester) async {
      await setUpWith();
      seedChatSession();
      container.read(selectedSessionIdProvider.notifier).select('acp-1');
      await pump(tester, size: size, compact: compact);

      expect(find.byKey(barKey), findsOneWidget);
      expect(
        inMark(find.byIcon(environmentGlyph(EnvironmentKind.windowsNative))),
        findsOneWidget,
      );
      expect(label('Windows'), labelled ? findsOneWidget : findsNothing);
      // The full name and the folder on hover, whatever the label shows.
      expect(inMark(find.byTooltip('Windows\n$folder')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a WSL session is named by its distribution', (tester) async {
    await setUpWith();
    seedChatSession(repositoryId: 'r-wsl');
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);

    expect(
      inMark(find.byIcon(environmentGlyph(EnvironmentKind.wsl))),
      findsOneWidget,
    );
    expect(label('WSL · archlinux'), findsOneWidget);
    expect(
      inMark(find.byTooltip('WSL · archlinux\n/home/me/demo')),
      findsOneWidget,
    );
  });

  testWidgets('on another machine the bar names that server', (tester) async {
    await setUpWith(
      extra: [
        activeMachineProvider.overrideWithValue(
          CompanionPairing(
            hostId: DeviceId.parse('11111111222222223333333344444444'),
            deviceId: DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd'),
            deviceKey: Uint8List.fromList(List<int>.filled(32, 7)),
            capabilities: CapabilitySet.all,
            relay: Uri.parse('wss://relay.example.com'),
            generation: 1,
            hostName: 'build-box',
          ),
        ),
      ],
    );
    seedChatSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);

    // "Windows" alone would read as this computer.
    expect(label('build-box'), findsOneWidget);
    expect(
      inMark(find.byTooltip('Windows on build-box\n$folder')),
      findsOneWidget,
    );
  });

  testWidgets("a session tab's tooltip names its environment", (tester) async {
    await setUpWith();
    seedChatSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);
    final agent = container
        .read(agentRegistryProvider)
        .displayNameFor(AgentIds.claudeAcp);
    final title = find.descendant(
      of: find.byType(TerminalTabChip),
      matching: find.text('Over ACP'),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Over ACP · $agent · Windows'), findsOneWidget);
  });

  testWidgets("a plain shell's foot names its machine", (tester) async {
    await setUpWith();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pump(tester);

    expect(
      inMark(find.byIcon(environmentGlyph(EnvironmentKind.windowsNative))),
      findsOneWidget,
    );
    expect(label('Windows'), findsOneWidget);
  });
}
