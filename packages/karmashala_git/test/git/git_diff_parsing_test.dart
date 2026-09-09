import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

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

  /// **`--porcelain=v2 --branch`**, which is what `statusWithBranch` asks for.
  ///
  /// v2 for its header lines: the branch, its upstream and the distance between
  /// them each get one, where v1 squeezed all three into `##
  /// work...origin/work [ahead 2, behind 1]` and said nothing at all when the
  /// branch was level. So the distance from the **upstream** comes free from a
  /// call the app already makes — a different comparison from `rev-list
  /// --count` against the base branch, which `parseAheadBehind` above owns and
  /// which is unchanged.
  ///
  /// The two record types v1 has no equivalent of are the ones worth writing
  /// tests for, because both are **silent** when missed: a rename puts two
  /// paths on one line separated by a tab, and an unmerged path stops being a
  /// `UU` entry and becomes its own `u` record.
  group('parseGitStatusV2', () {
    test('reads branch, upstream and divergence from the headers', () {
      final status = parseGitStatusV2(
        '# branch.oid 3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a\n'
        '# branch.head work\n'
        '# branch.upstream origin/work\n'
        '# branch.ab +2 -1\n'
        '1 .M N... 100644 100644 100644 $_sha $_sha lib/a.dart\n'
        '? new.txt\n',
      );
      expect(status.branch, 'work');
      expect(status.upstream, 'origin/work');
      expect(status.aheadOfUpstream, 2);
      expect(status.behindUpstream, 1);
      expect(status.changes.length, 2);
      expect(status.changes.first.path, 'lib/a.dart');
      expect(status.changes.first.staged, isFalse);
      expect(status.changes.first.unstaged, isTrue);
      expect(status.changes.last.type, FileChangeType.untracked);
    });

    test('a header is never read as a changed file', () {
      final status = parseGitStatusV2(porcelainV2(upstream: 'origin/main'));
      expect(status.changes, isEmpty);
      // `+0 -0` is git saying "level", which is not the same as not knowing.
      expect(status.aheadOfUpstream, 0);
      expect(status.behindUpstream, 0);
    });

    test('a branch with no upstream reports no distance', () {
      final status = parseGitStatusV2(
        porcelainV2(branch: 'work', modified: ['a']),
      );
      expect(status.branch, 'work');
      expect(status.upstream, isNull);
      expect(status.aheadOfUpstream, isNull);
      expect(status.changes.single.path, 'a');
    });

    test('an upstream that is gone has no distance to report', () {
      // Git prints `branch.upstream` and then omits `branch.ab`, because
      // `stat_tracking_info` cannot answer for a ref that is not there.
      final status = parseGitStatusV2(
        porcelainV2(
          branch: 'work',
          upstream: 'origin/work',
          ahead: null,
          behind: null,
        ),
      );
      expect(status.upstream, 'origin/work');
      expect(status.aheadOfUpstream, isNull);
      expect(status.behindUpstream, isNull);
    });

    test('a detached HEAD has no branch', () {
      expect(parseGitStatusV2(porcelainV2(branch: null)).branch, isNull);
    });

    test('a repository with no commits still names its branch', () {
      // v1 said `## No commits yet on main`, which had to be recognised by its
      // English. v2 says `# branch.oid (initial)` and names the branch in the
      // ordinary field.
      final status = parseGitStatusV2(
        porcelainV2(initial: true, untracked: ['README.md']),
      );
      expect(status.branch, 'main');
      expect(status.upstream, isNull);
      expect(status.changes.single.path, 'README.md');
    });

    test('ahead only', () {
      expect(
        parseGitStatusV2(
          porcelainV2(branch: 'w', upstream: 'origin/w', ahead: 3),
        ).aheadOfUpstream,
        3,
      );
    });

    test('output with no headers at all is still a file list', () {
      final status = parseGitStatusV2(
        '1 .M N... 100644 100644 100644 $_sha $_sha a\n',
      );
      expect(status.branch, isNull);
      expect(status.changes.single.path, 'a');
    });

    test('a staged change is staged, and `.` is not a status', () {
      // v2 writes `.` where v1 wrote a space, so a parse that kept looking for
      // the space would call every file both staged and unstaged.
      final status = parseGitStatusV2(porcelainV2(staged: ['lib/a.dart']));
      expect(status.changes.single.staged, isTrue);
      expect(status.changes.single.unstaged, isFalse);
      expect(status.changes.single.type, FileChangeType.modified);
    });

    test('a rename keeps its two tab-separated paths apart', () {
      // **The trap.** A `2` record ends `<path>\t<origPath>`, which v1 never
      // writes. Splitting the line on whitespace folds them into one nonsense
      // path and undercounts the dirty files by one per rename.
      final status = parseGitStatusV2(
        porcelainV2(renamed: {'lib/new.dart': 'lib/old.dart'}),
      );
      expect(status.changes.single.path, 'lib/new.dart');
      expect(status.changes.single.originalPath, 'lib/old.dart');
      expect(status.changes.single.type, FileChangeType.renamed);
    });

    test('an unmerged path is a conflict, named as one', () {
      // The second trap: v1 reported a conflict as an ordinary `UU` entry, so
      // a parse that handles only `1`, `2` and `?` drops conflicted files out
      // of the listing and a row mid-merge reports itself clean. It is no
      // longer `FileChangeType.unknown` either — *"changed (unrecognised git
      // status)"* was this parse shrugging at a status it could name exactly.
      final status = parseGitStatusV2(porcelainV2(unmerged: ['lib/a.dart']));
      expect(status.changes.single.path, 'lib/a.dart');
      expect(status.changes.single.type, FileChangeType.conflicted);
      expect(status.changes.single.conflict, MergeConflict.bothModified);
      expect(status.changes.single.staged, isTrue);
      expect(status.changes.single.unstaged, isTrue);
    });

    test('a path with spaces in it survives every record type', () {
      // The field counts are what make this work: the last field takes the
      // whole remainder of the line, so a space in a name is not a separator.
      final status = parseGitStatusV2(
        porcelainV2(
          modified: ['lib/two words.dart'],
          untracked: ['a b c.txt'],
          renamed: {'new name.dart': 'old name.dart'},
        ),
      );
      expect(status.changes.map((c) => c.path), [
        'lib/two words.dart',
        'new name.dart',
        'a b c.txt',
      ]);
      expect(status.changes[1].originalPath, 'old name.dart');
    });

    test('an ignored file is not a change', () {
      // `!` records only appear under `--ignored`, which nothing asks for — but
      // treating one as a change would make every build directory dirty.
      final status = parseGitStatusV2(
        '# branch.head main\n! build/app.exe\n? real.txt\n',
      );
      expect(status.changes.single.path, 'real.txt');
    });

    test('a truncated record is dropped, not guessed at', () {
      final status = parseGitStatusV2(
        '# branch.head main\n'
        '1 .M N... 100644\n'
        '? real.txt\n',
      );
      expect(status.changes.single.path, 'real.txt');
    });
  });

  /// **`u` records, written from `git status`'s own documentation.**
  ///
  /// `git-status(1)` gives an unmerged entry its own record:
  ///
  /// ```txt
  /// u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
  /// ```
  ///
  /// — three stage modes and three stage object names, because a conflict is a
  /// file that exists in up to three versions at once. A stage the merge has no
  /// version for is written `000000` with the null object name, which is how
  /// *both added* and *deleted by us* differ on the wire.
  ///
  /// `<XY>` is the same page's conflict table, and it is **not** a pair of
  /// index/work-tree letters: read one letter at a time, `AA` came out *added*
  /// and `DD` came out *deleted* — two confident wrong verbs about a file the
  /// merge has not finished with.
  group('an unmerged record is read as a conflict, and says which kind', () {
    const h1 = 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391';
    const h2 = '5c0d1b0e1a3e5f7a9b1c3d5e7f9a1b3c5d7e9f11';
    const h3 = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
    const nul = '0000000000000000000000000000000000000000';

    test('both modified — every stage present', () {
      // The ordinary conflict: the merge base and both sides all have the file.
      final status = parseGitStatusV2(
        'u UU N... 100644 100644 100644 100644 $h1 $h2 $h3 lib/src/app.dart\n',
      );
      final change = status.changes.single;
      expect(change.path, 'lib/src/app.dart');
      expect(change.type, FileChangeType.conflicted);
      expect(change.conflict, MergeConflict.bothModified);
      expect(change.conflict!.words, 'both modified');
      expect(change.staged, isTrue);
      expect(change.unstaged, isTrue);
      // One path per record. A rename is a `2`, and git writes the conflicted
      // path once — so there is no second path to be lost here.
      expect(change.originalPath, isNull);
    });

    test('both added — stage 1 is absent, and the kind still reads', () {
      final status = parseGitStatusV2(
        'u AA N... 000000 100644 100644 100644 $nul $h2 $h3 docs/notes.md\n',
      );
      expect(status.changes.single.conflict, MergeConflict.bothAdded);
      expect(status.changes.single.conflict!.words, 'both added');
      // The modes are read past, not kept: nothing draws a file mode, and
      // `<XY>` already says which sides hold the file.
      expect(status.changes.single.type, FileChangeType.conflicted);
    });

    test('deleted by us — our stage is absent, and the path keeps its space',
        () {
      final status = parseGitStatusV2(
        'u DU N... 100644 000000 100644 100644 $h1 $nul $h3 tool/build it.sh\n',
      );
      expect(status.changes.single.path, 'tool/build it.sh');
      expect(status.changes.single.conflict, MergeConflict.deletedByUs);
      expect(status.changes.single.conflict!.words, 'deleted by us');
    });

    test('a pair git has not documented is named unmerged, never guessed', () {
      final status = parseGitStatusV2(
        'u XX N... 100644 100644 100644 100644 $h1 $h2 $h3 lib/a.dart\n',
      );
      expect(status.changes.single.type, FileChangeType.conflicted);
      expect(status.changes.single.conflict, MergeConflict.unrecorded);
    });

    test('a truncated u record is dropped rather than half-read', () {
      expect(parseGitStatusV2('u UU N... 100644 100644\n').changes, isEmpty);
    });

    test('v1 reads the same seven pairs, because v1 is what the panel asks',
        () {
      // `ChangesService.changes` runs `--porcelain=v1`, so this is the parse
      // the Changes panel and the abort-merge reading actually see. v1 has no
      // separate record, and `AA`/`DD` are the two that a letter-at-a-time
      // read turns into a plain add and a plain delete.
      final changes = parseGitStatus(
        'UU lib/a.dart\n'
        'AA docs/notes.md\n'
        'DD tool/gone.sh\n'
        'UA added-by-them.txt\n'
        'M  ordinary.dart\n',
      );
      expect(changes.map((c) => c.type), [
        FileChangeType.conflicted,
        FileChangeType.conflicted,
        FileChangeType.conflicted,
        FileChangeType.conflicted,
        FileChangeType.modified,
      ]);
      expect(changes[1].conflict, MergeConflict.bothAdded);
      expect(changes[2].conflict, MergeConflict.bothDeleted);
      expect(changes[3].conflict, MergeConflict.addedByThem);
      expect(changes.last.conflict, isNull);
    });
  });
}

const _sha = '0000000000000000000000000000000000000000';
