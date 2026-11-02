import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/bot/presentation/bot_panel.dart';
import 'package:karmashala/src/features/sessions/presentation/queued_messages_strip.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fixtures.dart';
import 'bot_support.dart';

/// The server's word about an approval is not the person's: a small line, not
/// a bubble, and what it tells the agent stays with the agent.
void main() {
  late BotRig rig;

  setUp(() => rig = BotRig());

  final notice = botNotice(
    "Yes. Force close the terminal 'PowerShell'. It ran.",
    'The server ran it once, so do not run it again. Result:\n\n'
        '{"closed":true}\n\nSay in one short line what happened.',
  );

  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: BotPanelView(onClose: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TranscriptMessage said(String role, String text) =>
      TranscriptMessage(role: role, text: text, at: testTime);

  testWidgets('in the transcript it is a note, with no instruction', (
    tester,
  ) async {
    botRow(rig);
    final container = await rig.container(
      transcript: [
        said('user', 'close that terminal with kill'),
        said('agent', 'That needs your approval.'),
        said('user', notice),
        said('agent', 'The terminal was killed.'),
      ],
    );
    await pump(tester, container);

    expect(find.byKey(const ValueKey('transcript-notice')), findsOneWidget);
    expect(
      find.text(
        "Approval: Yes. Force close the terminal 'PowerShell'. It ran.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('do not run it again'), findsNothing);
    expect(find.textContaining('Say in one short line'), findsNothing);
    expect(find.textContaining('[Karmashala]'), findsNothing);
    expect(find.textContaining('closed'), findsNothing);
    expect(find.text('The terminal was killed.'), findsOneWidget);
  });

  test('a queued one is from Karmashala, not a schedule', () {
    final message = QueuedMessage(
      id: 'q',
      sessionId: 'bot-1',
      text: notice,
      seq: 1,
      state: QueuedMessageState.queued,
      origin: QueuedMessageOrigin.automation,
      createdAt: testTime,
      updatedAt: testTime,
    );
    expect(queuedSenderWords(message, titleOf: (_) => null), 'From Karmashala');
    expect(
      queuedMessageWords(message),
      "Approval: Yes. Force close the terminal 'PowerShell'. It ran.",
    );
  });
}
