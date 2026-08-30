import 'dart:io';

import 'package:chitragupta/src/features/git/data/hunk_patch.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fixtures are real `git diff` output, produced by real git against real
/// files (see the loop-53 report). Hand-written diffs are the classic way to
/// test a splitter into agreement with a format git does not actually emit.
String fixture(String name) =>
    File('test/features/git/fixtures/$name').readAsStringSync();

void main() {
  group('splitUnifiedDiff', () {
    test('separates files and their hunks', () {
      final files = splitUnifiedDiff(fixture('three_hunks.diff'));
      expect(files.map((f) => f.path), [
        'many.txt',
        'removed.txt',
        'small.txt',
      ]);

      final many = files.first;
      expect(many.hunks.length, 3);
      expect(many.hunks[0].oldStart, 1);
      expect(many.hunks[1].oldStart, 17);
      expect(many.hunks[1].heading, ' line 16');
      expect(many.hunks[2].oldStart, 35);
      expect(many.hunks.every((h) => h.delta == 0), isTrue);
    });

    test('reads counts, additions and removals off each hunk', () {
      final small = splitUnifiedDiff(
        fixture('three_hunks.diff'),
      ).firstWhere((f) => f.path == 'small.txt');
      final hunk = small.hunks.single;
      expect(hunk.oldStart, 1);
      expect(hunk.oldCount, 3);
      expect(hunk.newCount, 4);
      expect(hunk.delta, 1);
      expect(hunk.addedLines, 2);
      expect(hunk.removedLines, 1);
    });

    test('recognises a deletion', () {
      final removed = splitUnifiedDiff(
        fixture('three_hunks.diff'),
      ).firstWhere((f) => f.path == 'removed.txt');
      expect(removed.isDeleted, isTrue);
      expect(removed.isNew, isFalse);
      expect(removed.hunks.single.newCount, 0);
    });

    test('recognises a file a checkpoint saw appear', () {
      final files = splitUnifiedDiff(fixture('checkpoint_turn.diff'));
      final added = files.firstWhere((f) => f.path == 'brand_new.txt');
      expect(added.isNew, isTrue);
      expect(added.oldPath, 'brand_new.txt');
      expect(added.hunks.single.oldCount, 0);
      expect(added.hunks.single.lines, ['+fresh', '+file']);
    });

    test('a hunk header with no count means one line', () {
      final keep = splitUnifiedDiff(
        fixture('checkpoint_turn.diff'),
      ).firstWhere((f) => f.path == 'keep.txt');
      expect(keep.hunks.single.oldCount, 1);
      expect(keep.hunks.single.newCount, 1);
      expect(keep.hunks.single.header, '@@ -1 +1 @@');
    });

    test('round-trips the diff it was given', () {
      for (final name in [
        'three_hunks.diff',
        'shifting_hunks.diff',
        'checkpoint_turn.diff',
      ]) {
        final diff = fixture(name);
        final rebuilt = splitUnifiedDiff(
          diff,
        ).map((f) => f.text).join().replaceAll('\r\n', '\n');
        expect(rebuilt, diff.replaceAll('\r\n', '\n'), reason: name);
      }
    });

    test('survives text it cannot read', () {
      expect(splitUnifiedDiff(''), isEmpty);
      expect(splitUnifiedDiff('not a diff at all\n'), isEmpty);
      final odd = splitUnifiedDiff(
        'diff --git a/x b/x\nBinary files a/x and b/x differ\n',
      );
      expect(odd.single.isBinary, isTrue);
      expect(odd.single.hunks, isEmpty);
    });
  });

  group('buildPatch', () {
    late List<FilePatch> shifty;

    setUp(() => shifty = splitUnifiedDiff(fixture('shifting_hunks.diff')));

    test('one hunk on its own starts where the pre-image says', () {
      // Hunk 3 comes after a hunk that adds two lines. On its own, nothing has
      // shifted the file, so its post-image start is its pre-image start —
      // 35, not the 37 git wrote for the whole patch. Verified against real
      // `git apply --check`.
      final patch = patchForHunks(
        fixture('shifting_hunks.diff'),
        'shifty.txt',
        [2],
      );
      expect(patch, contains('@@ -35,6 +35,5 @@ line 34'));
      expect(patch, isNot(contains('inserted A')));
      expect(patch, startsWith('diff --git a/shifty.txt b/shifty.txt\n'));
      expect(patch, contains('--- a/shifty.txt\n+++ b/shifty.txt\n'));
    });

    test('a later hunk is shifted by the hunks kept before it', () {
      final patch = buildPatch(shifty, [
        const HunkSelection('shifty.txt', hunks: [0, 2]),
      ]);
      expect(patch, contains('@@ -1,6 +1,8 @@'));
      expect(patch, contains('@@ -35,6 +37,5 @@ line 34'));
      expect(patch, isNot(contains('line 20 CHANGED')));
    });

    test('keeping every hunk reproduces gitdiff exactly', () {
      final patch = buildPatch(shifty, [
        const HunkSelection('shifty.txt', hunks: [0, 1, 2]),
      ]);
      expect(patch, fixture('shifting_hunks.diff').replaceAll('\r\n', '\n'));
    });

    test('an empty selection produces nothing rather than a bad patch', () {
      expect(buildPatch(shifty, const []), isEmpty);
      expect(
        buildPatch(shifty, [const HunkSelection('shifty.txt', hunks: [])]),
        // No hunk indexes means the whole file, not "no hunks".
        isNotEmpty,
      );
      expect(
        buildPatch(shifty, [const HunkSelection('never-heard-of-it.txt')]),
        isEmpty,
      );
    });

    test('picks whole files out of a multi-file diff', () {
      final patch = patchForFiles(fixture('three_hunks.diff'), [
        'small.txt',
        'removed.txt',
      ]);
      expect(patch, contains('a/removed.txt'));
      expect(patch, contains('a/small.txt'));
      expect(patch, isNot(contains('many.txt')));
      // File order follows the diff, not the request, so the patch stays a
      // faithful subset of what git produced.
      expect(
        patch.indexOf('removed.txt'),
        lessThan(patch.indexOf('small.txt')),
      );
    });

    test('a binary file is all or nothing', () {
      final files = splitUnifiedDiff(
        'diff --git a/logo.png b/logo.png\n'
        'index 1111111..2222222 100644\n'
        'GIT binary patch\n'
        'literal 4\n'
        'zabcd\n',
      );
      final patch = buildPatch(files, [
        const HunkSelection('logo.png', hunks: [0]),
      ]);
      expect(patch, contains('GIT binary patch'));
    });
  });
}
