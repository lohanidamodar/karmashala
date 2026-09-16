import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench_conversation.dart';

void main() {
  group('nextMountedConversation', () {
    test('leaving the terminal mounts that session', () {
      expect(
        nextMountedConversation(
          current: null,
          sessionId: 's1',
          onTerminal: false,
        ),
        's1',
      );
    });

    test('going back to the terminal keeps it mounted', () {
      expect(
        nextMountedConversation(
          current: 's1',
          sessionId: 's1',
          onTerminal: true,
        ),
        's1',
      );
    });

    test('another session on the terminal lets it go', () {
      expect(
        nextMountedConversation(
          current: 's1',
          sessionId: 's2',
          onTerminal: true,
        ),
        isNull,
      );
      expect(
        nextMountedConversation(
          current: 's1',
          sessionId: null,
          onTerminal: true,
        ),
        isNull,
      );
    });

    test('nothing asked for mounts nothing', () {
      expect(
        nextMountedConversation(
          current: null,
          sessionId: 's1',
          onTerminal: true,
        ),
        isNull,
      );
    });
  });

  group('workspaceGroupConversationProvider', () {
    test('holds per group, and lets go on a switch then back', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final a = workspaceGroupConversationProvider('a');
      final b = workspaceGroupConversationProvider('b');
      container.listen(a, (_, _) {});
      container.listen(b, (_, _) {});

      container.read(a.notifier).settle(sessionId: 's1', onTerminal: false);
      expect(container.read(a), 's1');
      expect(container.read(b), isNull);

      container.read(a.notifier).settle(sessionId: 's1', onTerminal: true);
      expect(container.read(a), 's1');

      container.read(a.notifier).settle(sessionId: 's2', onTerminal: true);
      container.read(a.notifier).settle(sessionId: 's1', onTerminal: true);
      expect(container.read(a), isNull);
    });
  });
}
