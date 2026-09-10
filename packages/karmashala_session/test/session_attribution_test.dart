import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

void main() {
  const plain = SessionAttribution(
    sessionId: 'abc-123',
    title: 'Fix the build',
  );

  test('the prefix names the parent by id and title', () {
    expect(
      plain.render('do the thing'),
      '[message from the Karmashala session "Fix the build" (abc-123)]\n\n'
      'do the thing',
    );
  });

  test('rendering then stripping is the identity', () {
    const message = 'do the thing';
    expect(plain.stripFrom(plain.render(message)), message);
  });

  group('rebuilt, never parsed', () {
    test('a title containing a bracket round-trips whole', () {
      // This is the case a regex gets wrong: it would stop at the first `]` and
      // take "crash)] " plus the start of the real message with it.
      const bracketed = SessionAttribution(
        sessionId: 'x',
        title: 'Fix [urgent] crash',
      );
      const message = 'and then say ] here';
      expect(bracketed.stripFrom(bracketed.render(message)), message);
    });

    test('a message that merely looks like a prefix is left alone', () {
      const message =
          '[message from the Karmashala session "someone else" (zzz)]\n\n'
          'quoted by the user';
      expect(plain.stripFrom(message), message);
    });

    test('a renamed parent fails safe: nothing is stripped', () {
      // The strip is built from the *current* title, so a rename makes it not
      // match. The line stays visible, which is strictly better than a partial
      // strip that would delete words the sender wrote.
      final rendered = plain.render('the real message');
      const renamed = SessionAttribution(
        sessionId: 'abc-123',
        title: 'Fix the build (again)',
      );
      expect(renamed.stripFrom(rendered), rendered);
    });

    test('a message with no prefix at all is untouched', () {
      expect(plain.stripFrom('hello'), 'hello');
    });

    test('an attribution line with an empty body strips to empty', () {
      expect(plain.stripFrom(plain.line), '');
    });

    test('a prefix in the middle is not stripped', () {
      final message = 'I said: ${plain.line}\n\nand more';
      expect(plain.stripFrom(message), message);
    });
  });
}
