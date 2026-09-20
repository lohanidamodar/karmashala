import 'package:karmashala_mcp/instructions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:flutter_test/flutter_test.dart';

String textOf(Object? result) => [
  for (final block in ((result! as Map)['_mcpContent']! as List))
    if ((block as Map)['type'] == 'text') block['text']! as String,
].join('\n');

/// The guides, and the two mechanisms that stop them drifting away from the
/// code they describe.
///
/// The content assertions are deliberately about the *claims*, not the
/// wording. Each of the four facts checked here was read out of the
/// implementation before it was written down, and each one is the kind of
/// thing that stops being true quietly: if `terminal_run` ever starts guessing
/// an exit code, the guide saying it does not becomes a lie that no compiler
/// catches. Naming the claim in a test is the only way to make that a failure.
void main() {
  group('the topic listing', () {
    test('a bare call lists every topic with what it covers', () {
      final text = textOf(const InstructionsTools().call('instructions', {}));
      for (final guide in kMcpGuides) {
        expect(text, contains(guide.topic));
        expect(text, contains(guide.summary));
      }
    });

    test('a blank topic is the listing, not an error', () {
      expect(
        textOf(const InstructionsTools().call('instructions', {'topic': '  '})),
        contains('instructions(topic:'),
      );
    });

    test('an unknown topic is refused with the list of real ones', () {
      expect(
        () => const InstructionsTools().call('instructions', {
          'topic': 'nonsense',
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('nonsense'), contains('sessions')),
          ),
        ),
      );
    });

    test('topics are unique', () {
      final topics = [for (final guide in kMcpGuides) guide.topic];
      expect(topics.toSet(), hasLength(topics.length));
    });
  });

  group('what the guides actually claim', () {
    String guide(String topic) => textOf(
      const InstructionsTools().call('instructions', {'topic': topic}),
    );

    test('session_send is described as delivery, not completion', () {
      final text = guide('sessions');
      expect(text, contains('session_send'));
      expect(text, contains('delivered'));
      expect(text, contains('not a statement that the agent read the message'));
    });

    test('terminal_run is described as unable to invent an exit code', () {
      final text = guide('terminal');
      expect(text, contains('OSC 133'));
      expect(text, contains('exitCodeKnown'));
      expect(text, contains('UNKNOWN — not 0'));
    });

    test('checkpoint_restore is described as itself undoable', () {
      final text = guide('checkpoints');
      expect(text, contains('safetyCheckpointId'));
      expect(text, contains('takes a safety checkpoint before'));
    });

    test('worktree_create is described as not a delegation mechanism', () {
      final text = guide('workspace');
      expect(text, contains('worktree_create'));
      expect(text, contains('It is not a way to delegate'));
      expect(text, contains('open_new_session'));
      expect(text, contains('Nothing starts in it'));
    });

    test('flutter_reload is described as proving only that it landed', () {
      final text = guide('flutter-app');
      expect(text, contains('flutter_reload'));
      expect(text, contains('flutter_logs'));
      expect(text, contains('lasts only as long as'));
      expect(text, contains('fullRestart'));
    });

    test('the browser guide states the trust boundary and the gate', () {
      final text = guide('browser');
      expect(text, contains('untrusted-page-content'));
      expect(text, contains('an attack, not a request'));
      expect(text, contains('browser_evaluate'));
      expect(text, contains('one-time grant'));
      expect(text, contains('retry: never'));
    });
  });

  group('the tool rosters are generated, not typed', () {
    test('a guide lists exactly the catalogued tools it claims', () {
      for (final guide in kMcpGuides) {
        final text = guide.render();
        for (final name in guide.tools) {
          expect(text, contains(name), reason: '${guide.topic} omits $name');
        }
        expect(guide.tools, isNotEmpty, reason: '${guide.topic} claims none');
      }
    });

    test('a roster carries each tool\'s annotations', () {
      final text = const InstructionsTools().call('instructions', {
        'topic': 'checkpoints',
      });
      expect(textOf(text), contains('checkpoint_restore  — destructive'));
      expect(
        textOf(text),
        contains('checkpoint_list  — read-only, idempotent'),
      );
    });

    test('a guide names no tool the catalogue does not have', () {
      // `tools` is filtered through the catalogue, so it can never name a dead
      // tool — the drift risk is in what a guide *declares*. An `extraTools`
      // entry that no longer exists silently contributes nothing, which is
      // exactly the quiet shrinkage the roster is meant to prevent.
      for (final guide in kMcpGuides) {
        for (final name in guide.extraTools) {
          expect(
            kMcpToolAnnotations.containsKey(name),
            isTrue,
            reason: '${guide.topic} names $name, which is not served',
          );
        }
      }
    });

    test('membership follows the catalogue, so a new tool cannot hide', () {
      // The anti-drift property in one assertion: the browser guide does not
      // hold a list of browser tools, it asks the catalogue. Every catalogued
      // `browser_` tool is therefore in it by construction.
      final browser = kMcpGuides.firstWhere((g) => g.topic == 'browser');
      expect(
        browser.tools.toSet(),
        kMcpToolAnnotations.keys.where((n) => n.startsWith('browser_')).toSet(),
      );
    });
  });

  group('the tool itself', () {
    test('it is served and annotated as reading nothing', () {
      final names = [
        for (final schema in LauncherControlServer.toolSchemas) schema['name'],
      ];
      expect(names, contains('instructions'));
      expect(kMcpToolAnnotations['instructions']?.readOnly, isTrue);
    });

    test('the schema description names a fact worth the call', () {
      final schema = instructionsToolSchemas.single;
      expect(schema['name'], 'instructions');
      expect(schema['description'], contains('session_send'));
      expect(schema['description'], contains('OSC 133'));
    });

    /// **The pane/agent rule, stated on both surfaces.**
    ///
    /// A pane and an agent are different things, and the two families are
    /// split along exactly that line — so a reader who arrives at either one
    /// must find the rule there rather than having to have read the other.
    test('both guides state that a pane and an agent are not the same', () {
      // Collapsed, because the guides are prose wrapped for reading and where
      // a sentence happens to break is not what is being pinned.
      String body(String topic) => kMcpGuides
          .firstWhere((g) => g.topic == topic)
          .render()
          .replaceAll(RegExp(r'\s+'), ' ');

      for (final topic in ['sessions', 'terminal']) {
        final text = body(topic);
        expect(
          text,
          contains(
            'A pane exists whether or not it contains an agent; an agent is '
            'the recognized process currently running inside a pane.',
          ),
          reason: 'the $topic guide does not state the rule',
        );
        // And each says which half it owns, so the rule is actionable rather
        // than a definition sitting on its own.
        expect(
          text,
          contains('terminal_'),
          reason: '$topic names no terminal half',
        );
        expect(
          text,
          contains('session_'),
          reason: '$topic names no session half',
        );
      }
    });

    test('the sessions guide teaches the two rules a wait turns on', () {
      final sessions = kMcpGuides
          .firstWhere((g) => g.topic == 'sessions')
          .render();
      // done vs idle: "finished something" must not read like "never started".
      expect(sessions, contains('never started'));
      // And a timeout is not proof that nothing was sent.
      expect(sessions, contains('does not prove that no input was sent'));
      expect(sessions, contains('session_wait'));
    });

    test('it handles only itself', () {
      expect(InstructionsTools.handles('instructions'), isTrue);
      expect(InstructionsTools.handles('instructions_list'), isFalse);
      expect(
        () => const InstructionsTools().call('list_projects', const {}),
        throwsArgumentError,
      );
    });
  });
}
