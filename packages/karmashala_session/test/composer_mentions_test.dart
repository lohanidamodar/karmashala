import 'package:karmashala_session/mentions.dart';
import 'package:test/test.dart';

void main() {
  group('findMentions', () {
    test('reads each kind and where it sits', () {
      const text =
          'Fix @app/lib/main.dart and @lib/ per @diff, @diff:main, '
          '@terminal:"Build server" @session:Plan @subagent:"r1 report" '
          '@https://example.com/a?b=1.';
      final found = findMentions(text);
      expect(
        [for (final m in found) m.kind],
        [
          MentionKind.file,
          MentionKind.folder,
          MentionKind.diff,
          MentionKind.diff,
          MentionKind.terminal,
          MentionKind.session,
          MentionKind.subagent,
          MentionKind.url,
        ],
      );
      expect(
        [for (final m in found) m.argument],
        [
          'app/lib/main.dart',
          'lib/',
          null,
          'main',
          'Build server',
          'Plan',
          'r1 report',
          'https://example.com/a?b=1',
        ],
      );
      expect(
        text.substring(found[4].start, found[4].end),
        '@terminal:"Build server"',
      );
      expect(text.substring(found[2].start, found[2].end), '@diff');
    });

    test('leaves addresses, bare words and half-typed kinds alone', () {
      expect(findMentions('mail a@b.com or @someone'), isEmpty);
      expect(findMentions('@terminal: and @session:'), isEmpty);
      expect(findMentions('@"unclosed'), isEmpty);
    });

    test('a file named like a kind is a file', () {
      final found = findMentions('see @diff.md and (@diffs/x)');
      expect(
        [for (final m in found) m.kind],
        [MentionKind.file, MentionKind.file],
      );
      expect(found.first.argument, 'diff.md');
    });

    test('mentionText quotes what has a space and round-trips', () {
      for (final (kind, arg) in [
        (MentionKind.file, 'app/lib/main.dart'),
        (MentionKind.file, 'my dir/a b.txt'),
        (MentionKind.folder, 'lib/src/'),
        (MentionKind.diff, null),
        (MentionKind.diff, 'origin/main'),
        (MentionKind.terminal, 'Build server'),
        (MentionKind.session, 'Fix login'),
        (MentionKind.url, 'https://x.dev/p'),
      ]) {
        final text = mentionText(kind, arg);
        final found = mentionAt(text, 0);
        expect(found?.kind, kind, reason: text);
        expect(found?.argument, arg, reason: text);
        expect(found?.end, text.length, reason: text);
      }
    });
  });

  group('contexts', () {
    test('a short body goes whole, fenced past its own backticks', () {
      final message = messageWithMentionContexts('Look at @diff', [
        const MentionContext(
          token: '@diff',
          description: 'uncommitted changes',
          body: 'a\n```\nb',
          language: 'diff',
        ),
      ]);
      expect(
        message,
        'Look at @diff\n\n'
        '@diff — uncommitted changes:\n'
        '````diff\n'
        'a\n```\nb\n'
        '````',
      );
    });

    test('a long body is cut to the cap and says so', () {
      final lines = [for (var i = 0; i < 5000; i++) 'line $i'].join('\n');
      final message = messageWithMentionContexts('', [
        MentionContext(
          token: '@terminal:Build',
          description: 'last lines of Build',
          body: lines,
          keepTail: true,
        ),
      ]);
      expect(message.length, lessThan(kMentionContextCap + 200));
      expect(message, contains('showing the last'));
      expect(message, contains('line 4999'));
      expect(message, isNot(contains('line 0\n')));

      final head = capMentionBody(lines, cap: 100);
      expect(head.cut, isTrue);
      expect(head.text, startsWith('line 0\n'));
      expect(head.text.endsWith('\n'), isFalse);
    });

    test('splitMentionedMessage reads sections and paths back', () {
      final message = messageWithMentionContexts(
        'Compare @app/a.dart with @terminal:"Dev server" and @app/a.dart',
        const [
          MentionContext(
            token: '@terminal:"Dev server"',
            description: 'last 3 lines of Dev server',
            body: 'one\ntwo\nthree',
          ),
        ],
      );
      final read = splitMentionedMessage(message);
      expect(
        read.text,
        'Compare @app/a.dart with @terminal:"Dev server" and @app/a.dart',
      );
      expect(read.paths, ['app/a.dart']);
      expect(read.sections, hasLength(1));
      final section = read.sections.single;
      expect(section.kind, MentionKind.terminal);
      expect(section.token, '@terminal:"Dev server"');
      expect(section.body, 'one\ntwo\nthree');
      expect(section.language, 'text');
    });

    test('a heading-like line with no fence stays text', () {
      final read = splitMentionedMessage('@diff — what:\nnot a fence');
      expect(read.sections, isEmpty);
      expect(read.text, '@diff — what:\nnot a fence');
    });
  });
}
