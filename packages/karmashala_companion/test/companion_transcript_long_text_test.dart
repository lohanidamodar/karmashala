import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_test_support.dart';

/// What an agent really sends a phone: a hash with no break in it, a code line
/// wider than the screen, a path twelve directories deep — in every speaker's
/// frame, at a phone's width, a tablet's, and with the text turned up.
void main() {
  final unbroken = 'a1b2c3d4' * 40;
  final deepPath =
      '/Users/someone/Documents/projects/${'nested-directory/' * 12}'
      'a_file_with_a_rather_long_name_indeed.dart';
  final wideCode = 'final value = ${'someFunction(argument) + ' * 12}0;';

  final turns = <CompanionChatMessage>[
    CompanionChatMessage(role: 'user', text: 'Look at $deepPath and $unbroken'),
    CompanionChatMessage(
      role: 'agent',
      text:
          '<thinking>$unbroken</thinking>Here it is:\n\n```dart\n$wideCode\n'
          '```\n\nSee `$deepPath`.',
    ),
    CompanionChatMessage(role: 'tool', text: 'Bash($deepPath $unbroken)'),
    CompanionChatMessage(role: 'error', text: unbroken),
  ];

  FakeCompanionGateway gatewayWith(CompanionChatMessage turn) =>
      FakeCompanionGateway.paired(
        sessions: [summary('s1', title: 'Fix the login flow')],
        transcripts: {
          's1': [turn],
        },
      );

  /// Opens the reasoning too, so the unfolded turn is what gets measured.
  Future<void> unfold(WidgetTester tester) async {
    final thought = find.textContaining('Thought');
    if (thought.evaluate().isEmpty) return;
    await tester.tap(thought.first);
    await tester.pump();
    expect(find.textContaining('a1b2c3d4'), findsWidgets);
  }

  for (final turn in turns) {
    for (final textScale in const [1.0, 1.3]) {
      testWidgets('a long ${turn.role} turn fits a phone at ${textScale}x', (
        tester,
      ) async {
        await pumpPhone(
          tester,
          gateway: gatewayWith(turn),
          home: const SessionViewScreen(sessionId: 's1'),
          textScale: textScale,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await unfold(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a long ${turn.role} turn fits a tablet at ${textScale}x', (
        tester,
      ) async {
        await pumpTablet(
          tester,
          gateway: gatewayWith(turn),
          home: const SessionViewScreen(sessionId: 's1'),
          textScale: textScale,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await unfold(tester);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
