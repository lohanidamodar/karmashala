import 'package:karmashala_core/paths.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/testing.dart';

/// The chain Codex's self-updater left on the owner's machine, measured
/// 2026-09-07 with `Link.targetSync()` from Dart:
///
/// ```txt
/// …\OpenAI\Codex\bin  ->  …\.codex\packages\standalone\current\bin
///                     ->  …\releases\0.153.4-x86_64-pc-windows-msvc\bin
/// ```
///
/// The disk is described the way the real one measured: `existsSync` on the
/// stored leaf answers a flat **false** rather than raising, so nothing here
/// leans on an exception to tell an unreachable file from an absent one.
const _stable = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe';
const _stableDir = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin';
const _current = r'C:\Users\d\.codex\packages\standalone\current';
const _release =
    r'C:\Users\d\.codex\packages\standalone\releases'
    r'\0.153.4-x86_64-pc-windows-msvc';
const _real = '$_release\\bin\\codex.exe';

FakePathProbe codexProbe() => FakePathProbe(
  files: const {_real},
  links: const {_stableDir: '$_current\\bin', _current: _release},
);

void main() {
  group('readExecutable', () {
    test('a file that is there reads as usable, with nothing to resolve', () {
      final probe = FakePathProbe(files: const {r'C:\tools\codex.exe'});
      final reading = readExecutable(
        r'C:\tools\codex.exe',
        probe,
        context: p.windows,
      );
      expect(reading.reachability, ExecutableReachability.usable);
      expect(reading.resolved, isNull);
      expect(reading.isRepairable, isFalse);
    });

    test('a plain empty path reads as missing', () {
      expect(
        readExecutable(
          r'C:\gone\codex.exe',
          FakePathProbe(),
          context: p.windows,
        ).reachability,
        ExecutableReachability.missing,
      );
    });

    test('a junction chain to a real file reads as unreachable', () {
      // The §19 rule in one assertion: an installed-but-untraversable Codex
      // must not answer the same as an uninstalled one, because "install it"
      // and "the route to it is broken" are opposite instructions. And the
      // file's real location comes back so a repair has somewhere to move to.
      final reading = readExecutable(_stable, codexProbe(), context: p.windows);
      expect(reading.reachability, ExecutableReachability.unreachable);
      expect(reading.resolved, _real);
      expect(reading.isRepairable, isTrue);
    });

    test('a junction that leads nowhere reads as missing', () {
      // The route *was* completed — every link read, and the file at the end
      // of it is gone. That is evidence of absence, so it is reported as such
      // rather than hidden behind "could not look".
      final probe = FakePathProbe(
        links: const {_stableDir: '$_current\\bin', _current: _release},
      );
      final reading = readExecutable(_stable, probe, context: p.windows);
      expect(reading.reachability, ExecutableReachability.missing);
      expect(reading.resolved, isNull);
    });

    test('a chain that cannot be walked reads as unreachable', () {
      // A junction whose reparse data the OS will not hand over. Nothing was
      // established, so nothing is claimed — least of all "not installed".
      final reading = readExecutable(
        r'C:\a\codex.exe',
        _UnreadableLink(),
        context: p.windows,
      );
      expect(reading.reachability, ExecutableReachability.unreachable);
      expect(reading.isRepairable, isFalse);
    });

    test('an outright refusal reads as unreachable', () {
      final probe = FakePathProbe(refused: const {r'C:\mnt'});
      expect(
        readExecutable(
          r'C:\mnt\share\codex.exe',
          probe,
          context: p.windows,
        ).reachability,
        ExecutableReachability.unreachable,
      );
    });
  });

  group('resolveReparsePoints', () {
    test('follows the whole junction chain to the real executable', () {
      expect(
        resolveReparsePoints(_stable, codexProbe(), context: p.windows),
        _real,
      );
    });

    test('leaves a path with no reparse point on it alone', () {
      final probe = FakePathProbe(files: const {r'C:\tools\codex.exe'});
      expect(
        resolveReparsePoints(r'C:\tools\codex.exe', probe, context: p.windows),
        r'C:\tools\codex.exe',
      );
    });

    test('resolves a relative link target against the link\'s parent', () {
      // POSIX symlinks are commonly relative; joining one onto the wrong
      // directory would silently produce a path that cannot exist.
      final probe = FakePathProbe(
        files: const {'/opt/agents/0.9/codex'},
        links: const {'/opt/agents/current': '0.9'},
      );
      expect(
        resolveReparsePoints(
          '/opt/agents/current/codex',
          probe,
          context: p.posix,
        ),
        '/opt/agents/0.9/codex',
      );
    });

    test('gives up on a cycle rather than spinning', () {
      final probe = FakePathProbe(
        links: const {r'C:\a': r'C:\b', r'C:\b': r'C:\a'},
      );
      expect(
        resolveReparsePoints(r'C:\a\codex.exe', probe, context: p.windows),
        isNull,
      );
    });

    test('never asks about the root, which cannot be a reparse point', () {
      final probe = FakePathProbe(files: const {r'C:\tools\codex.exe'});
      resolveReparsePoints(r'C:\tools\codex.exe', probe, context: p.windows);
      expect(probe.queries, isNot(contains(r'C:\')));
    });
  });

  group('traversablePath', () {
    test('hands back a usable path unchanged', () {
      // A working install keeps its stable path. Resolving it would swap it for
      // a version-pinned one that rots on the next update, for no benefit.
      final probe = FakePathProbe(
        files: const {r'C:\tools\codex.exe'},
        links: const {r'C:\tools': r'C:\real'},
      );
      expect(
        traversablePath(r'C:\tools\codex.exe', probe, context: p.windows),
        r'C:\tools\codex.exe',
      );
    });

    test('trades an unreachable path for the resolved one', () {
      expect(traversablePath(_stable, codexProbe(), context: p.windows), _real);
    });

    test('answers null when the resolved path holds nothing either', () {
      final probe = FakePathProbe(
        links: const {_stableDir: '$_current\\bin', _current: _release},
      );
      expect(traversablePath(_stable, probe, context: p.windows), isNull);
    });

    test('answers null for a plainly missing path', () {
      expect(
        traversablePath(
          r'C:\gone\codex.exe',
          FakePathProbe(),
          context: p.windows,
        ),
        isNull,
      );
    });
  });
}

/// A component that reports itself a link and then refuses to say where it
/// leads — a junction whose reparse data the OS will not hand over.
class _UnreadableLink implements PathProbe {
  @override
  bool? fileExists(String path) => false;

  @override
  bool isLink(String path) => path == r'C:\a';

  @override
  String? linkTarget(String path) => null;
}
