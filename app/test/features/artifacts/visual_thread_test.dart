import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/presentation/session_visual_block.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// What `visualize` drew shows in the thread where it was called, updates in
/// place when drawn again, and is the same in the dashboard's peek.
void main() {
  final projected = <TranscriptMessage>[
    TranscriptMessage(role: 'user', text: 'Run the suite.', at: testTime),
    TranscriptMessage(role: 'agent', text: 'Starting the run.', at: testTime),
    TranscriptMessage(
      role: 'tool',
      text: '',
      tool: const ToolActivity(
        name: 'mcp__karmashala__visualize',
        subject: 'progress',
        output: '{"id": "build", "kind": "progress", "revision": 1}',
      ),
      at: testTime,
    ),
    TranscriptMessage(role: 'agent', text: 'All green.', at: testTime),
  ];

  late FakeDataServer server;
  late ProviderContainer container;

  SessionVisual progress(double value, {int revision = 1}) => SessionVisual(
    sessionId: 's1',
    id: 'build',
    kind: 'progress',
    title: 'Suite',
    data: {'value': value, 'max': 100.0, 'status': 'running'},
    revision: revision,
    createdAt: testTime,
    updatedAt: testTime,
  );

  setUp(() async {
    final db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Over ACP',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
      ),
    );
    server.drawVisual(progress(40));
    container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(projected),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeAcp,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.protocol,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pump(
    WidgetTester tester, {
    bool peek = false,
    Size size = const Size(1440, 900),
    double textScale = 1,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark()
              : AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: SessionTranscriptView(
                sessionId: 's1',
                resumesInBackground: peek,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('drawn under the words before its call, updated in place', (
    tester,
  ) async {
    await pump(tester);
    final block = find.byKey(const ValueKey('session-visual-build'));
    expect(block, findsOneWidget);
    expect(find.text('Suite'), findsWidgets);
    expect(find.text('40%'), findsOneWidget);
    final words = tester.getTopLeft(find.textContaining('Starting the run.'));
    final done = tester.getTopLeft(find.textContaining('All green.'));
    expect(tester.getTopLeft(block).dy, greaterThan(words.dy));
    expect(tester.getTopLeft(block).dy, lessThan(done.dy));

    server.drawVisual(progress(75, revision: 2));
    await tester.pumpAndSettle();
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('40%'), findsNothing);
    expect(block, findsOneWidget);
  });

  testWidgets('a visual drawn later in the same session joins the thread', (
    tester,
  ) async {
    await pump(tester);
    server.drawVisual(
      SessionVisual(
        sessionId: 's1',
        id: 'cov',
        kind: 'chart',
        data: {
          'type': 'line',
          'series': [
            {
              'data': [
                {'x': 1, 'y': 50},
                {'x': 2, 'y': 55},
              ],
            },
          ],
        },
        revision: 1,
        createdAt: testTime,
        updatedAt: testTime,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SeriesChart), findsOneWidget);
  });

  testWidgets('the dashboard peek draws it too', (tester) async {
    await pump(tester, peek: true);
    expect(find.byKey(const ValueKey('session-visual-build')), findsOneWidget);
  });

  testWidgets('a bad spec is contained, with why, the thread untouched', (
    tester,
  ) async {
    server.drawVisual(
      SessionVisual(
        sessionId: 's1',
        id: 'build',
        kind: 'progress',
        data: const {'value': 'lots'},
        revision: 2,
        createdAt: testTime,
        updatedAt: testTime,
      ),
    );
    await pump(tester);
    expect(find.byKey(const ValueKey('fence-failed')), findsOneWidget);
    expect(find.textContaining('All green.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a kept image is fetched over the data channel', (tester) async {
    // A 1×1 PNG.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    server.drawVisual(
      SessionVisual(
        sessionId: 's1',
        id: 'build',
        kind: 'image',
        data: {
          'fileName': 'shot.png',
          'mimeType': 'image/png',
          'size': png.length,
        },
        revision: 3,
        createdAt: testTime,
        updatedAt: testTime,
      ),
      image: png,
    );
    await pump(tester);
    expect(
      find.descendant(
        of: find.byType(SessionVisualBlock),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });

  for (final size in const [Size(360, 800), Size(1440, 900)]) {
    for (final brightness in Brightness.values) {
      testWidgets('fits at ${size.width} px, text ×1.6, ${brightness.name}', (
        tester,
      ) async {
        await pump(tester, size: size, textScale: 1.6, brightness: brightness);
        expect(find.byType(VisualCard), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
