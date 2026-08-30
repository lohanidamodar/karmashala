import 'package:chitragupta/src/features/git/data/git_diff_parsing.dart';
import 'package:chitragupta/src/features/git/domain/diff_line.dart';
import 'package:chitragupta/src/features/git/domain/diff_stat.dart';
import 'package:chitragupta/src/features/git/domain/file_change.dart';
import 'package:flutter_test/flutter_test.dart';

final _us = String.fromCharCode(0x1f);

void main() {
  group('parseGitStatus', () {
    test('classifies staged/unstaged/untracked/added/deleted', () {
      const out =
          'M  staged_mod.dart\n'
          ' M unstaged_mod.dart\n'
          'A  added.dart\n'
          ' D deleted.dart\n'
          '?? new.dart\n';
      final changes = parseGitStatus(out);
      expect(changes.map((c) => c.path), [
        'staged_mod.dart',
        'unstaged_mod.dart',
        'added.dart',
        'deleted.dart',
        'new.dart',
      ]);
      expect(changes[0].staged, isTrue);
      expect(changes[0].unstaged, isFalse);
      expect(changes[1].staged, isFalse);
      expect(changes[1].unstaged, isTrue);
      expect(changes[2].type, FileChangeType.added);
      expect(changes[3].type, FileChangeType.deleted);
      expect(changes[4].type, FileChangeType.untracked);
    });

    test('handles renames with old -> new', () {
      final changes = parseGitStatus('R  old.dart -> new.dart\n');
      expect(changes.single.type, FileChangeType.renamed);
      expect(changes.single.path, 'new.dart');
      expect(changes.single.originalPath, 'old.dart');
    });

    test('empty status yields no changes', () {
      expect(parseGitStatus(''), isEmpty);
    });
  });

  group('parseGitLog', () {
    test('parses unit-separated commit lines', () {
      final out =
          'abc123${_us}Ada${_us}First commit\n'
          'def456${_us}Bob${_us}Second commit\n';
      final commits = parseGitLog(out);
      expect(commits.length, 2);
      expect(commits[0].sha, 'abc123');
      expect(commits[0].author, 'Ada');
      expect(commits[0].subject, 'First commit');
      expect(commits[1].subject, 'Second commit');
    });
  });

  group('parseUnifiedDiff', () {
    test('classifies headers, hunks, additions and removals', () {
      const diff =
          'diff --git a/x b/x\n'
          'index 111..222 100644\n'
          '--- a/x\n'
          '+++ b/x\n'
          '@@ -1,2 +1,2 @@\n'
          ' context\n'
          '-old\n'
          '+new\n';
      final lines = parseUnifiedDiff(diff);
      final kinds = lines.map((l) => l.kind).toList();
      expect(kinds, [
        DiffLineKind.meta, // diff --git
        DiffLineKind.meta, // index
        DiffLineKind.meta, // ---
        DiffLineKind.meta, // +++
        DiffLineKind.hunk,
        DiffLineKind.context,
        DiffLineKind.removed,
        DiffLineKind.added,
      ]);
    });
  });

  group('parseNumstat', () {
    test('sums added and removed lines across files', () {
      const out = '12\t3\tlib/a.dart\n0\t7\tlib/b.dart\n';
      final stat = parseNumstat(out);
      expect(stat.added, 12);
      expect(stat.removed, 10);
      expect(stat.files, 2);
      expect(stat.binaryFiles, 0);
    });

    test('a binary file counts as a file and as no lines', () {
      const out = '5\t1\tlib/a.dart\n-\t-\tassets/icon.png\n';
      final stat = parseNumstat(out);
      expect(stat.added, 5);
      expect(stat.removed, 1);
      expect(stat.files, 2);
      expect(stat.binaryFiles, 1);
    });

    test('no output is an empty stat, not a failure', () {
      expect(parseNumstat(''), DiffStat.none);
      expect(parseNumstat('\n\n'), DiffStat.none);
    });

    test('a rename with a tab-separated old and new path still counts', () {
      expect(parseNumstat('3\t2\told.dart\tnew.dart').files, 1);
    });
  });

  group('parseAheadBehind', () {
    test('left is behind, right is ahead', () {
      expect(
        parseAheadBehind('2\t5\n'),
        const AheadBehind(ahead: 5, behind: 2),
      );
    });

    test('space separated output parses the same way', () {
      expect(parseAheadBehind('0 3'), const AheadBehind(ahead: 3, behind: 0));
    });

    test('anything that is not two numbers is "could not tell"', () {
      expect(parseAheadBehind(''), isNull);
      expect(parseAheadBehind('fatal: bad revision'), isNull);
      expect(parseAheadBehind('3'), isNull);
    });
  });
}
