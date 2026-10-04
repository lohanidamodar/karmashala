import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage, kAgentSwitchRole;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/acp_session_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/switch_agent_control.dart';
import 'package:karmashala/src/features/agents/application/installation_labels.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **One thread, many agents**: a switched session's chat names each turn's
/// agent, draws "Continued with …" where another took over (the packet it was
/// handed folded inside), and the composer's Switch agent control hands the
/// session over in place. A session that never switched looks as before.
void main() {
  const registry = AgentRegistry.builtIn;
  final claude = registry.displayNameFor(AgentIds.claudeCode);
  final acp = registry.displayNameFor(AgentIds.claudeAcp);

  TranscriptMessage said(String role, String text, String? installation) =>
      TranscriptMessage(
        role: role,
        text: text,
        at: testTime,
        agentInstallationId: installation,
      );

  final switched = [
    said('user', 'make the cart faster', 'cc'),
    said('agent', 'Cached the totals.', 'cc'),
    said('agent', 'Anything else?', 'cc'),
    said(kAgentSwitchRole, 'CARRIED PACKET', 'acp'),
    said('agent', 'Picking it up here.', 'acp'),
  ];

  group('chatMessagesFromTranscript', () {
    TranscriptAgent? agentOf(String id) => switch (id) {
      'cc' => (name: claude, agentId: AgentIds.claudeCode),
      'acp' => (name: acp, agentId: AgentIds.claudeAcp),
      _ => null,
    };

    test('the switch becomes a divider and the first agent row of a turn '
        'names its agent', () {
      final out = chatMessagesFromTranscript(switched, agentOf: agentOf);
      expect(out.map((m) => (m.role, m.agentName)), [
        ('user', null),
        ('agent', claude),
        ('agent', null),
        (kAgentSwitchNoticeRole, acp),
        ('agent', acp),
      ]);
      expect(out[3].text, 'CARRIED PACKET');
    });

    test('a session that never switched carries no names', () {
      final out = chatMessagesFromTranscript([
        said('user', 'hi', null),
        said('agent', 'hello', null),
      ], agentOf: agentOf);
      expect(out.map((m) => m.agentName), [null, null]);
      expect(out.map((m) => m.role), ['user', 'agent']);
    });
  });

  group('in the chat', () {
    late TestMachine db;
    late FakeDataServer server;

    setUp(() async {
      db = TestMachine();
      server = FakeDataServer()..runsOn(db);
      server.environmentRows.upsert(windowsEnv());
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      server.installationRows
        ..insert(
          agentInstallation(
            id: 'acp',
            agentId: AgentIds.claudeAcp,
            path: r'C:\Users\me\.bin\claude-agent-acp.exe',
          ),
        )
        ..insert(agentInstallation(id: 'cc'))
        ..insert(
          agentInstallation(
            id: 'cx',
            agentId: AgentIds.codex,
            path: r'C:\Users\me\.bin\codex.exe',
          ),
        );
      server.sessionWork.running.add('s1');
      db.server.sessionRows.insert(
        session(
          id: 's1',
          agentInstallationId: 'acp',
          status: SessionStatus.running,
        ),
      );
    });

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required Size size,
      bool switches = true,
      AgentActivityStatus activity = AgentActivityStatus.idle,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          ...fakeTerminalOverrides(machine: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          serverOfferProvider.overrideWithValue(
            ServerOffer(
              sameMachine: true,
              serverOs: 'windows',
              features: {
                'sessions.send',
                'sessions.interrupt',
                if (switches) 'sessions.switchAgent',
              },
            ),
          ),
          sessionRunningOnHostProvider.overrideWithValue((_) => true),
          sessionActivityLookupProvider.overrideWithValue((_) => activity),
          sessionChatTranscriptProvider.overrideWith(
            (ref, id) => Stream.value(switched),
          ),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          sessionDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    for (final (name, size) in [
      ('phone', const Size(390, 844)),
      ('desktop', const Size(1440, 900)),
    ]) {
      testWidgets('on a $name the divider names the new agent and opens on '
          'the packet; turns are labelled', (tester) async {
        await pump(tester, size: size);

        expect(find.text('Continued with $acp'), findsOneWidget);
        expect(find.text('CARRIED PACKET'), findsNothing);
        expect(find.text('make the cart faster'), findsOneWidget);
        final bylines = tester
            .widgetList<Text>(find.byKey(const ValueKey('agent-byline')))
            .map((t) => t.data);
        expect(bylines, [claude, acp]);

        await tester.tap(find.text('Continued with $acp'));
        await tester.pumpAndSettle();
        expect(find.text('CARRIED PACKET'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('on a $name Switch agent lists the agents, marks the one '
          'that resumes, and switches in place', (tester) async {
        await pump(tester, size: size);

        await tester.tap(find.byKey(const ValueKey('switch-agent')));
        await tester.pumpAndSettle();
        expect(find.text('resumes its conversation'), findsOneWidget);
        expect(find.text('Continue in a new session…'), findsOneWidget);
        final codex = registry.displayNameFor(AgentIds.codex);
        await tester.tap(find.text(codex).last);
        await tester.pumpAndSettle();

        expect(server.sessionWork.switches.single.targetInstallationId, 'cx');
        expect(server.sessionWork.switches.single.sessionId, 's1');
        expect(tester.takeException(), isNull);
      });
    }

    for (final (name, size) in [
      ('phone', const Size(390, 844)),
      ('desktop', const Size(1440, 900)),
    ]) {
      testWidgets('on a $name the face names the running agent, its row is '
          'checked "running now", and each other row says what happens', (
        tester,
      ) async {
        await pump(tester, size: size);
        expect(find.text(acp), findsWidgets);

        await tester.tap(find.byKey(const ValueKey('switch-agent')));
        await tester.pumpAndSettle();
        expect(find.text('running now'), findsOneWidget);
        expect(find.text('Runs this session now.'), findsOneWidget);
        expect(
          find.textContaining('Stops $acp; continues $claude'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('on a $name every agent is refused, with the reason, while '
          'a turn runs', (tester) async {
        await pump(
          tester,
          size: size,
          activity: AgentActivityStatus.working,
        );
        await tester.tap(find.byKey(const ValueKey('switch-agent')));
        await tester.pumpAndSettle();
        expect(find.text(kSwitchWhileBusy), findsNWidgets(2));
        await tester.tap(find.text(registry.displayNameFor(AgentIds.codex)).last);
        await tester.pumpAndSettle();
        expect(server.sessionWork.switches, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('on a $name two installations of one agent are told apart '
          'and the other one can be picked', (tester) async {
        server.installationRows.insert(
          agentInstallation(id: 'cc2', path: r'D:\tools\claude\claude.exe'),
        );
        await pump(tester, size: size);
        await tester.tap(find.byKey(const ValueKey('switch-agent')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(RegExp('^${RegExp.escape(claude)} · ')),
          findsNWidgets(2),
        );
        await tester.tap(find.byKey(const ValueKey('switch-to-cc2')));
        await tester.pumpAndSettle();
        expect(server.sessionWork.switches.single.targetInstallationId, 'cc2');
        expect(tester.takeException(), isNull);
      });
    }

    test('installations of one agent in two environments are named by where '
        'they live; a lone one by its name alone', () {
      final labels = installationLabels(
        [
          agentInstallation(id: 'w'),
          agentInstallation(
            id: 'l',
            environmentId: 'wsl',
            path: '/home/me/.local/bin/claude',
          ),
          agentInstallation(
            id: 'x',
            agentId: AgentIds.codex,
            path: r'C:\bin\codex.exe',
          ),
        ],
        registry: registry,
        environmentName: (id) => id == 'wsl' ? 'WSL' : 'Windows',
      );
      expect(labels, {
        'w': '$claude · Windows',
        'l': '$claude · WSL',
        'x': registry.displayNameFor(AgentIds.codex),
      });
    });

    testWidgets('a server that cannot switch draws no control', (
      tester,
    ) async {
      await pump(tester, size: const Size(1440, 900), switches: false);
      expect(find.byKey(const ValueKey('switch-agent')), findsNothing);
    });

    test('whether a session speaks ACP follows its row\'s agent', () async {
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      final sub = container.listen(isAcpSessionProvider('s1'), (_, _) {});
      addTearDown(sub.close);
      expect(sub.read(), isTrue);

      final row = db.server.sessionRows.getById('s1')!;
      db.server.sessionRows.put(row.copyWith(agentInstallationId: 'cc'));
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(sub.read(), isFalse);
    });
  });
}
