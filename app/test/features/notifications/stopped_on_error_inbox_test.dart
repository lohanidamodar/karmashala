import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/sessions/application/session_input.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A turn an API error ended is in the inbox as stopped, in the error's own
/// words, with a Resume that sends the session "continue".
class _Input extends SessionInput {
  _Input(super.ref);

  final sent = <(String, String)>[];

  @override
  Future<bool> send(String sessionId, String text, {String? requestId}) async {
    sent.add((sessionId, text));
    return true;
  }
}

void main() {
  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390x844', Size(390, 844)),
  ]) {
    testWidgets('$name: stopped on an error, with Resume', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = FakeDataServer()
        ..environmentRows.upsert(windowsEnv())
        ..projectRows.insert(project())
        ..repositoryRows.insert(repository());
      _Input? input;
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
          sessionInputProvider.overrideWith((ref) => input = _Input(ref)),
        ],
      );
      addTearDown(container.dispose);
      server.attention.setInbox(
        AttentionInbox(
          items: [
            InboxItem(
              session: const WatchedSession(
                key: AgentSessionKey('claudeCode', 'cli-1'),
                label: 'Round 15e',
                openId: 's1',
                imported: false,
              ),
              kind: InboxItemKind.failed,
              at: testTime,
              detail: 'Stopped: connection lost mid-response',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: size.width,
                child: const AttentionInboxView(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Stopped on an error'), findsOneWidget);
      expect(
        find.textContaining('Stopped: connection lost mid-response'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Resume'));
      await tester.pumpAndSettle();
      expect(input!.sent, [('s1', 'continue')]);
    });
  }
}
