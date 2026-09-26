import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:test/test.dart';

/// Claude Code's screen while it works, as 2.1.274 draws it: what it has taken
/// sits above the rule — answered, or queued with a `❯` of its own — and the
/// composer is the row between the rules.
class FakeComposer {
  FakeComposer({this.folds = 0});

  /// How many Returns are read as the end of a paste and folded into a
  /// newline, leaving the message in the field. The real composer does this to
  /// a Return that reaches it in the same read as the text it follows.
  int folds;

  String field = '';
  final List<String> queued = [];
  final List<String> written = [];

  List<String> get rows => [
    '● I will start on that now.',
    for (final message in queued) ...[
      for (final (i, line) in message.split('\n').indexed)
        i == 0 ? '❯ $line' : '  $line',
    ],
    '─' * 40,
    ...(field.isEmpty
        ? const ['❯']
        : [
            for (final (i, line) in field.split('\n').indexed)
              i == 0 ? '❯ $line' : '  $line',
          ]),
    '─' * 40,
    '  ⏸ plan mode on (shift+tab to cycle) · esc to interrupt',
  ];

  bool type(String sessionId, String text) {
    written.add(text);
    field += text;
    return true;
  }

  bool press(String sessionId, String keys) {
    written.add(keys);
    if (keys != '\r') return true;
    if (field.isEmpty) return true;
    if (folds > 0) {
      folds--;
      field += '\n';
      return true;
    }
    queued.add(field.trimRight());
    field = '';
    return true;
  }
}

SessionMessageTypist typistFor(
  FakeComposer composer, {
  List<String>? markers = const ['❯', '›'],
}) => SessionMessageTypist(
  readScreen: (_) => composer.rows,
  markersFor: (_) => markers,
  type: composer.type,
  press: composer.press,
  poll: const Duration(milliseconds: 1),
  typedPatience: const Duration(milliseconds: 100),
  sendPatience: const Duration(milliseconds: 100),
);

void main() {
  group('SessionMessageTypist', () {
    test('types the message and presses Return once', () async {
      final composer = FakeComposer();
      final sent = await typistFor(composer).send('s1', 'run the tests');

      expect(sent, isTrue);
      expect(composer.queued, ['run the tests']);
      expect(composer.written.where((w) => w == '\r'), hasLength(1));
    });

    test(
      'presses Return again when the composer folded it into a newline',
      () async {
        final composer = FakeComposer(folds: 1);
        final sent = await typistFor(composer).send('s1', 'run the tests');

        expect(sent, isTrue);
        expect(composer.queued, ['run the tests']);
        expect(composer.written.where((w) => w == '\r'), hasLength(2));
        expect(composer.field, isEmpty);
      },
    );

    test('says so when the composer keeps the message', () async {
      final composer = FakeComposer(folds: 99);

      await expectLater(
        typistFor(composer).send('s1', 'run the tests'),
        throwsA(isA<SessionPromptRefusal>()),
      );
      expect(composer.queued, isEmpty);
      // Three Returns, then the refusal — not a Return per poll for ever.
      expect(composer.written.where((w) => w == '\r'), hasLength(3));
    });

    test('a message the agent already took is not sent twice', () async {
      // The queued row holds the same words: what is read back is the
      // composer's own rows, so they do not count as the message staying.
      final composer = FakeComposer()..queued.add('run the tests');
      final sent = await typistFor(composer).send('s1', 'run the tests');

      expect(sent, isTrue);
      expect(composer.queued, ['run the tests', 'run the tests']);
      expect(composer.written.where((w) => w == '\r'), hasLength(1));
    });

    test(
      'an agent whose screen was never measured is left at one Return',
      () async {
        final composer = FakeComposer(folds: 99);
        final sent = await typistFor(
          composer,
          markers: null,
        ).send('s1', 'run the tests');

        expect(sent, isTrue);
        expect(composer.written.where((w) => w == '\r'), hasLength(1));
      },
    );

    test('without a live pane nothing is typed', () async {
      final typist = SessionMessageTypist(
        readScreen: (_) => null,
        markersFor: (_) => const ['❯'],
        type: (_, _) => false,
        press: (_, _) => fail('pressed without a pane'),
      );

      expect(await typist.send('s1', 'run the tests'), isFalse);
    });

    test('an empty message is not a send', () async {
      final composer = FakeComposer();

      expect(await typistFor(composer).send('s1', '   '), isFalse);
      expect(composer.written, isEmpty);
    });
  });
}
