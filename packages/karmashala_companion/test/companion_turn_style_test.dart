import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import 'companion_test_support.dart';

/// The one table that says how each speaker's turn is drawn on the phone.
void main() {
  final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
  final semantic = SemanticColors.forBrightness(Brightness.light);

  test('each speaker has its word, glyph and frame', () {
    final user = companionTurnStyle('user', scheme, semantic);
    expect((user.label, user.icon), ('YOU', AppIcons.userCircle));
    expect(user.colour, scheme.primary);
    expect(user.fill, isNotNull);

    final tool = companionTurnStyle('tool', scheme, semantic);
    expect((tool.label, tool.icon), ('TOOL', AppIcons.terminal));

    final error = companionTurnStyle('error', scheme, semantic);
    expect((error.label, error.icon), ('ERROR', AppIcons.warning));
    expect(error.colour, semantic.failure);
  });

  test('anything else is the agent, unframed, with its avatar ring', () {
    for (final role in const ['agent', 'assistant', '']) {
      final agent = companionTurnStyle(role, scheme, semantic);
      expect(agent.label, 'AGENT', reason: role);
      expect(agent.fill, isNull);
      expect(agent.edge, isNull);
      expect(agent.ring, isNotNull);
    }
  });

  testWidgets('the transcript draws every speaker from the table', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(
        sessions: [summary('s1')],
        transcripts: {
          's1': const [
            CompanionChatMessage(role: 'user', text: 'hello'),
            CompanionChatMessage(role: 'tool', text: 'ls'),
            CompanionChatMessage(role: 'error', text: 'boom'),
            CompanionChatMessage(role: 'agent', text: 'hi'),
          ],
        },
      ),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    for (final label in const ['YOU', 'TOOL', 'ERROR', 'AGENT']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });
}
