// Renders round 63's Stop and Detach into PNGs: the composer's Stop while the
// agent works, its "Still working" escalation, the parent's line once a child
// is detached, the New-session dialog's "Link to", and the dashboard before
// and after a detach. Under tool/ so `flutter test` never picks it up; run it
// from app/:
//
//   flutter test tool/stop_detach_screenshot.dart
//
// Images land in build/stop-detach-shots/.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_turn_stop.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../test/features/overview/mission_fixture.dart';
import '../test/features/terminal/fake_instance.dart';
import '../test/support/fake_command_runner.dart';
import '../test/support/fake_data_server.dart';
import '../test/support/fakes.dart';
import '../test/support/fixtures.dart';
import '../test/support/test_machine.dart';

const _outDir = 'build/stop-detach-shots';

/// Every font the app bundles — without this flutter_test draws boxes.
Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

Future<void> _save(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });

Future<void> _frames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

void main() {
  setUpAll(_loadBundledFonts);

  /// A server with one ACP session mid-turn, as the chat shots want it.
  Future<
    ({
      FakeDataServer server,
      TestMachine db,
      StreamController<AgentStatusReport> statuses,
    })
  >
  world() async {
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows
      ..insert(project(id: 'p1', name: 'karmashala', path: r'C:\src\ks'))
      ..insert(project(id: 'p2', name: 'site', path: r'C:\src\site'));
    server.repositoryRows
      ..insert(repository(id: 'r1', projectId: 'p1', path: r'C:\src\ks'))
      ..insert(
        repository(
          id: 'r2',
          projectId: 'p2',
          name: 'site',
          path: r'C:\src\site',
        ),
      );
    server.installationRows
      ..insert(agentInstallation())
      ..insert(
        agentInstallation(
          id: 'acp',
          agentId: AgentIds.claudeAcp,
          path: r'C:\Users\me\.bin\claude-agent-acp.exe',
        ),
      );
    server.sessionWork
      ..typesSends = true
      ..running.add('acp-1')
      ..busy.add('acp-1');
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        title: 'Round 63 · Stop and detach',
        status: SessionStatus.running,
      ),
    );
    return (
      server: server,
      db: db,
      statuses: StreamController<AgentStatusReport>.broadcast(),
    );
  }

  Future<void> chat(
    WidgetTester tester,
    String name, {
    required Size size,
    bool phone = false,
    double textScale = 1,
    String typed = '',
    bool escalate = false,
    bool detachedChild = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final w = await world();
    addTearDown(w.statuses.close);
    final messages = [
      TranscriptMessage(
        role: 'user',
        text:
            'Make Stop always there while you work, and let me detach a '
            'sub-session.',
        at: testTime,
      ),
      TranscriptMessage(
        role: 'agent',
        text:
            'Started two sub-sessions: one for the composer, one for the '
            'server side.',
        at: testTime.add(const Duration(seconds: 30)),
      ),
    ];
    if (detachedChild) {
      w.server.drawVisual(
        SessionVisual(
          sessionId: 'acp-1',
          id: 'detached-child-1',
          kind: 'note',
          data: const {'text': '"Server side of detach" was detached'},
          revision: 1,
          createdAt: testTime.add(const Duration(minutes: 1)),
          updatedAt: testTime.add(const Duration(minutes: 1)),
        ),
      );
    }
    final container = ProviderContainer(
      overrides: [
        await w.server.override(),
        ...fakeTerminalOverrides(machine: w.db),
        clockProvider.overrideWithValue(
          FixedClock(testTime.add(const Duration(minutes: 2))),
        ),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {
              'sessions.send',
              'sessions.interrupt',
              'sessions.queue',
              'sessions.queue.control',
              'sessions.queue.manage',
              'sessions.detach',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
        agentSessionStatusProvider.overrideWith((ref, id) => w.statuses.stream),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(messages),
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
    final key = GlobalKey();
    final theme = AppTheme.dark().copyWith(
      platform: phone ? TargetPlatform.android : TargetPlatform.windows,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepaintBoundary(
              key: key,
              child: UiDensity.wrap(context, child!),
            ),
          ),
          home: Scaffold(
            body: SessionTranscriptView(
              sessionId: 'acp-1',
              holdForPrompt: phone,
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
    w.statuses.add(
      AgentStatusReport(
        agentId: AgentIds.claudeAcp,
        sessionId: 'acp-1',
        status: AgentActivityStatus.working,
        observedAt: testTime,
        source: AgentStatusSource.protocol,
        working: AgentWorkingDetail(
          word: 'Thinking…',
          since: testTime.add(const Duration(seconds: 40)),
        ),
      ),
    );
    await _frames(tester);
    if (typed.isNotEmpty) {
      await tester.enterText(find.byType(TextField).last, typed);
      await _frames(tester, 2);
    }
    if (escalate) {
      await tester.tap(find.byKey(const ValueKey('composer-stop')));
      await _frames(tester);
      await tester.pump(kStopEscalationAfter);
      await _frames(tester);
    }
    await _save(tester, key, name);
    expect(tester.takeException(), isNull);
    // The working line ticks: end the turn so nothing is left pending.
    w.statuses.add(
      AgentStatusReport(
        agentId: AgentIds.claudeAcp,
        sessionId: 'acp-1',
        status: AgentActivityStatus.idle,
        observedAt: testTime,
        source: AgentStatusSource.protocol,
      ),
    );
    await _frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets(
    'stop, desktop',
    (t) => chat(t, 'stop-desktop-1440', size: _desktop),
  );
  testWidgets(
    'stop, desktop, typing',
    (t) => chat(
      t,
      'stop-desktop-1440-typing',
      size: _desktop,
      typed: 'then run the tests',
    ),
  );
  testWidgets(
    'stop, phone',
    (t) => chat(t, 'stop-phone-390', size: _phone, phone: true),
  );
  testWidgets(
    'stop, phone, typing, text 1.6',
    (t) => chat(
      t,
      'stop-phone-390-typing-text160',
      size: _phone,
      phone: true,
      textScale: 1.6,
      typed: 'then run the tests',
    ),
  );
  testWidgets(
    'escalation, desktop',
    (t) => chat(t, 'escalation-desktop-1440', size: _desktop, escalate: true),
  );
  testWidgets(
    'escalation, phone, text 1.6',
    (t) => chat(
      t,
      'escalation-phone-390-text160',
      size: _phone,
      phone: true,
      textScale: 1.6,
      escalate: true,
    ),
  );
  testWidgets(
    'the parent\'s line after a detach',
    (t) => chat(
      t,
      'parent-note-desktop-1440',
      size: _desktop,
      detachedChild: true,
    ),
  );

  Future<void> dialog(
    WidgetTester tester,
    String name, {
    required Size size,
    bool phone = false,
    double textScale = 1,
    bool linkToParent = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final w = await world();
    final data = await w.server.connect();
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        agentUsageProvider.overrideWith(
          (ref, installation) => const AsyncLoading<AgentUsage>(),
        ),
        ...fakeTerminalOverrides(machine: w.db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    final key = GlobalKey();
    final theme = AppTheme.dark().copyWith(
      platform: phone ? TargetPlatform.android : TargetPlatform.windows,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepaintBoundary(
              key: key,
              child: UiDensity.wrap(context, child!),
            ),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => NewSessionDialog.show(
                  context,
                  parentSessionId: 'acp-1',
                  linkToParent: linkToParent,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _save(tester, key, name);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets(
    'link to, from a session, desktop',
    (t) => dialog(t, 'new-session-link-desktop-1440', size: _desktop),
  );
  testWidgets(
    'link to, from the dashboard, phone, text 1.6',
    (t) => dialog(
      t,
      'new-session-link-dashboard-phone-390-text160',
      size: _phone,
      phone: true,
      textScale: 1.6,
      linkToParent: false,
    ),
  );

  /// The realistic board with [detached] children's parent links cleared, as
  /// a detach leaves them.
  Future<void> board(
    WidgetTester tester,
    String name, {
    required Size size,
    bool phone = false,
    Set<String> detached = const {},
  }) async {
    final key = GlobalKey();
    final sessions = [
      for (final s in MissionFixture.realisticSessions())
        detached.contains(s.id)
            ? (
                id: s.id,
                title: s.title,
                project: s.project,
                machine: s.machine,
                agent: s.agent,
                state: s.state,
                age: s.age,
                parent: null,
                report: s.report,
              )
            : s,
    ];
    await pumpMission(
      tester,
      fixture: MissionFixture(sessions: sessions),
      prefsDir: Directory.systemTemp.createTempSync('ks-r63-board'),
      size: size,
      phone: phone,
      boundary: key,
    );
    await settleMission(tester);
    await _save(tester, key, name);
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  }

  // The first child of the busy parent, detached.
  final child = MissionFixture.realisticSessions()
      .firstWhere((s) => s.parent != null)
      .id;
  testWidgets(
    'dashboard before a detach',
    (t) => board(t, 'dashboard-before-1440', size: _desktop),
  );
  testWidgets(
    'dashboard after a detach',
    (t) => board(t, 'dashboard-after-1440', size: _desktop, detached: {child}),
  );
  testWidgets(
    'dashboard after a detach, phone',
    (t) => board(
      t,
      'dashboard-after-phone-390',
      size: _phone,
      phone: true,
      detached: {child},
    ),
  );
}
