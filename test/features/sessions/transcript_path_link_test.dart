import 'package:agent_cli/process.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The detector, on its own. A false positive here is worse than a miss: an
/// underlined `and/or` that does nothing on click makes the whole feature look
/// broken, so the negative list is the longer one on purpose.
void main() {
  /// Every token [text] would linkify, in order. Uses the same anchored match
  /// the markdown syntax uses, walked position by position exactly as the
  /// inline parser walks it.
  List<String> links(String text) {
    final found = <String>[];
    var i = 0;
    while (i < text.length) {
      final token = transcriptPathAt(text, i);
      if (token == null) {
        i++;
        continue;
      }
      found.add(token.text);
      i += token.text.length;
    }
    return found;
  }

  group('what becomes a link', () {
    test('the owner\'s own path, relative and extensioned', () {
      expect(
        links('built windows/installer/output/Karmashala-Setup-1.4.0.exe now'),
        ['windows/installer/output/Karmashala-Setup-1.4.0.exe'],
      );
    });

    test('a two-segment relative file', () {
      expect(links('see lib/main.dart'), ['lib/main.dart']);
    });

    test('a Windows absolute path, either slash', () {
      expect(links(r'open C:\Users\dlohani\notes.md'), [
        r'C:\Users\dlohani\notes.md',
      ]);
      expect(links('open C:/Users/dlohani/notes.md'), [
        'C:/Users/dlohani/notes.md',
      ]);
    });

    test('a UNC path', () {
      expect(links(r'at \\wsl.localhost\Ubuntu\home\me\src'), [
        r'\\wsl.localhost\Ubuntu\home\me\src',
      ]);
    });

    test('a POSIX absolute path with two segments', () {
      expect(links('cd /home/me/src'), ['/home/me/src']);
    });

    test('a dot-relative path', () {
      expect(links('run ./tool/build.dart and ../sibling/x'), [
        './tool/build.dart',
        '../sibling/x',
      ]);
    });

    test('a directory, when it ends in a separator and carries two', () {
      expect(links('under lib/src/features/ there'), ['lib/src/features/']);
    });

    test('a dotfile directory', () {
      expect(links('edit .github/workflows/ci.yml'), [
        '.github/workflows/ci.yml',
      ]);
    });

    test('a line suffix travels with the token but not into the path', () {
      final token = transcriptPathAt('lib/main.dart:12:5', 0)!;
      expect(token.text, 'lib/main.dart:12:5');
      expect(token.path, 'lib/main.dart');
      expect(token.line, 12);
    });

    test('a sentence\'s full stop is left outside the link', () {
      expect(links('it is in lib/main.dart.'), ['lib/main.dart']);
    });
  });

  group('what must stay prose', () {
    test('a URL is never carved up', () {
      expect(links('see https://example.com/a/b/c.html for more'), isEmpty);
      expect(links('http://host/x/y.png'), isEmpty);
    });

    test('slash-joined prose', () {
      expect(links('use and/or, n/a, 1/2 and he/she/they'), isEmpty);
    });

    test('a bare word with a dot', () {
      expect(links('e.g. version 1.4.0 of Node.js. Done.'), isEmpty);
    });

    test('a lone filename with no directory', () {
      expect(links('open main.dart please'), isEmpty);
    });

    test('a lone slash-word', () {
      expect(links('the /tmp folder'), isEmpty);
    });

    test('a tilde path, which we could never resolve', () {
      expect(links(r'edit ~/.claude/settings.json'), isEmpty);
    });

    test('a date', () {
      expect(links('on 2/9/2026 it broke'), isEmpty);
    });
  });

  group('markdown labels', () {
    test('a path inside a link label is left to the link', () {
      const source = 'see [lib/main.dart](https://example.com)';
      expect(insideMarkdownLabel(source, source.indexOf('lib/')), isTrue);
    });

    test('a path outside any label is fair game', () {
      const source = 'see [docs](https://x) and lib/main.dart';
      expect(insideMarkdownLabel(source, source.indexOf('lib/')), isFalse);
    });

    test('a label on an earlier line does not leak downwards', () {
      const source = '[a](b)\nlib/main.dart';
      expect(insideMarkdownLabel(source, source.indexOf('lib/')), isFalse);
    });
  });

  group('resolution', () {
    test('a relative path resolves against the session working directory', () {
      expect(
        resolveTranscriptPath(
          'windows/installer/output/Karmashala-Setup-1.4.0.exe',
          workingDirectory: '/home/me/src/app',
          context: p.posix,
        ),
        '/home/me/src/app/windows/installer/output/Karmashala-Setup-1.4.0.exe',
      );
    });

    test('an absolute path is left where it is', () {
      expect(
        resolveTranscriptPath(
          '/var/log/x.log',
          workingDirectory: '/home/me',
          context: p.posix,
        ),
        '/var/log/x.log',
      );
    });

    test('a Windows path stays Windows whatever context is asked', () {
      expect(
        resolveTranscriptPath(
          r'C:\src\app\x.dart',
          workingDirectory: '/home/me',
          context: p.posix,
        ),
        r'C:\src\app\x.dart',
      );
    });

    test('a Windows session joins the Windows way', () {
      expect(
        resolveTranscriptPath(
          r'lib\main.dart',
          workingDirectory: r'C:\src\app',
          context: p.windows,
        ),
        r'C:\src\app\lib\main.dart',
      );
    });

    test('WSL paths are POSIX, unlike the WSL *store* home', () {
      expect(transcriptPathContext(EnvironmentKind.wsl), p.posix);
      expect(transcriptPathContext(EnvironmentKind.ssh), p.posix);
      expect(transcriptPathContext(EnvironmentKind.windowsNative), p.windows);
    });
  });
}
