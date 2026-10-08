import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/application/remote_links.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:agent_cli/stream.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// A web link in the conversation opens in the browser when clicked. The owner
/// (2026-10-08): "clicking on urls did not open it in the browser" — under a
/// pointer they used to be inert.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late List<String> opened;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    opened = [];
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Work',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.external,
      ),
    );
  });

  Future<void> pump(WidgetTester tester, String text) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await server.override(),
          openExternalUrlProvider.overrideWithValue((url) async {
            opened.add(url);
            return true;
          }),
          sessionTranscriptProvider.overrideWith(
            (ref, id) => Stream.value([
              SessionEvent(
                id: 1,
                sessionId: 's1',
                seq: 0,
                type: SessionEventTypes.agentMessage,
                payload: '{"text":"See [the docs](https://example.com/docs)."}',
                createdAt: testTime,
              ),
            ]),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The recognizer of the first link span in the conversation, or null.
  TapGestureRecognizer? firstLink(WidgetTester tester) {
    TapGestureRecognizer? link;
    for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
      widget.text.visitChildren((span) {
        if (span is TextSpan &&
            span.toPlainText().contains('the docs') &&
            span.recognizer is TapGestureRecognizer) {
          link ??= span.recognizer! as TapGestureRecognizer;
        }
        return true;
      });
    }
    return link;
  }

  testWidgets('a click on a web link opens it in the browser, no dialog', (
    tester,
  ) async {
    await pump(tester, '');

    final link = firstLink(tester);
    expect(link, isNotNull, reason: 'the link is live under a pointer');
    link!.onTap!();
    await tester.pumpAndSettle();

    expect(opened, ['https://example.com/docs']);
    expect(find.text('Open in the browser?'), findsNothing);
  });
}
