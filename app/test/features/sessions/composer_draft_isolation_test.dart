import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart'
    show textLeftAfterSend;
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

/// **What a person types stays theirs**: the peek and the tab of one session
/// share its draft, but a view closing never adds its text to words being
/// typed in another; a view moved to another session never carries one
/// session's text to the other; and a send takes away only what it sent.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.sessionWork
      ..typesSends = true
      ..resumesOnSend = true;
    for (final id in ['one', 'two']) {
      db.server.sessionRows.insert(
        session(
          id: id,
          agentInstallationId: 'acp',
          status: SessionStatus.failed,
        ),
      );
    }
  });

  /// Mounts whatever [views] says, rebuilt each time it changes.
  Future<void> pump(
    WidgetTester tester,
    ValueNotifier<List<(String key, String sessionId)>> views,
  ) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {
              'sessions.send',
              'sessions.interrupt',
              'sessions.send.resumes',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => false),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
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
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: views,
              builder: (_, shown, _) => Column(
                children: [
                  for (final (key, sessionId) in shown)
                    Expanded(
                      key: ValueKey(key),
                      child: SessionTranscriptView(sessionId: sessionId),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder box(String key) => find
      .descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      )
      .last;

  String textIn(WidgetTester tester, String key) =>
      tester.widget<TextField>(box(key)).controller!.text;

  testWidgets('a view of the session closing never adds its words to what is '
      'being typed in another; the next view gets both', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final views = ValueNotifier([('tab', 'one'), ('peek', 'one')]);
    await pump(tester, views);

    await tester.enterText(box('tab'), 'left in the tab');
    await tester.enterText(box('peek'), 'typing in the peek');
    views.value = [('peek', 'one')];
    await tester.pumpAndSettle();

    expect(textIn(tester, 'peek'), 'typing in the peek');

    views.value = [];
    await tester.pumpAndSettle();
    views.value = [('again', 'one')];
    await tester.pumpAndSettle();
    expect(textIn(tester, 'again'), contains('left in the tab'));
    expect(textIn(tester, 'again'), contains('typing in the peek'));
  });

  testWidgets('a view moved to another session keeps each one\'s words to '
      'itself', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final views = ValueNotifier([('view', 'one')]);
    await pump(tester, views);

    await tester.enterText(box('view'), 'meant for one');
    views.value = [('view', 'two')];
    await tester.pumpAndSettle();
    expect(textIn(tester, 'view'), isEmpty);

    views.value = [('view', 'one')];
    await tester.pumpAndSettle();
    expect(textIn(tester, 'view'), 'meant for one');
  });

  test('a send takes only what it sent out of the box', () {
    expect(textLeftAfterSend('hello', 'hello'), '');
    expect(
      textLeftAfterSend('hello\n\na note offered meanwhile', 'hello'),
      'a note offered meanwhile',
    );
    expect(textLeftAfterSend('replaced', 'hello'), 'replaced');
  });
}
