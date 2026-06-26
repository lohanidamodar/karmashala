import 'package:chitragupta/src/features/git/data/git_diff_parsing.dart';
import 'package:chitragupta/src/features/git/domain/diff_line.dart';
import 'package:chitragupta/src/features/git/domain/file_change.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
