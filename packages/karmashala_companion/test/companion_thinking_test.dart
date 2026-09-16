import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/transcript.dart';

import 'companion_test_support.dart';

/// Reasoning arrives wrapped in `<thinking>` from some agents and `<thought>`
/// from others; the desktop folds both away, and so must the phone.
void main() {
  for (final tag in const ['thinking', 'thought']) {
    testWidgets('an agent turn folds <$tag> into the accordion', (
      tester,
    ) async {
      await pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(
          sessions: [summary('s1')],
          transcripts: {
            's1': [
              CompanionChatMessage(
                role: 'agent',
                text: '<$tag>weigh the options</$tag>The answer is 42.',
              ),
            ],
          },
        ),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      expect(find.byType(ThinkingAccordion), findsOneWidget);
      expect(
        find.textContaining('<$tag>', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('The answer is 42.', findRichText: true),
        findsWidgets,
      );
    });
  }
}
