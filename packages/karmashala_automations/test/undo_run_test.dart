import 'package:test/test.dart';
import 'package:karmashala_automations/runs.dart';

/// Undo is asymmetric: the files always, the commits only sometimes.
///
/// The refusal is a function rather than two sentences precisely so the
/// tooltip and the write path cannot drift, and these are the words both show.
void main() {
  RunCommit commit(String sha) => RunCommit(sha: sha, subject: 'work on $sha');

  RunCommits summary({
    String? baseSha = 'base00000000',
    int commits = 2,
    int? published = 0,
  }) => RunCommits(
    baseSha: baseSha,
    commits: [for (var i = 0; i < commits; i++) commit('sha$i')],
    published: published,
  );

  test('local commits with a base to return to may be dropped', () {
    expect(undoCommitsRefusal(summary()), isNull);
    expect(canUndoRunCommits(summary()), isTrue);
  });

  test('a run that committed nothing has nothing to drop', () {
    final refusal = undoCommitsRefusal(summary(commits: 0));
    expect(refusal, 'This run made no commits.');
  });

  group('published history is refused outright', () {
    test('all of them on a remote', () {
      final refusal = undoCommitsRefusal(summary(published: 2))!;
      expect(refusal, contains('already on a remote'));
      expect(refusal, contains('rewrite published history'));
      expect(refusal, contains('revert them instead'));
      // The reading is only as fresh as the last fetch, and it says so.
      expect(refusal, contains('git fetch'));
      expect(canUndoRunCommits(summary(published: 2)), isFalse);
    });

    test('one of them is enough', () {
      final refusal = undoCommitsRefusal(summary(commits: 3, published: 1))!;
      expect(refusal, contains('1 of these 3 commits'));
      expect(refusal, contains('revert them instead'));
    });
  });

  group('a reading that could not be taken is never read as zero', () {
    test('git could not be asked which remotes hold them', () {
      final refusal = undoCommitsRefusal(summary(published: null))!;
      expect(refusal, contains('could not be asked'));
      expect(refusal, contains('not recorded'));
      expect(refusal, contains('could not take'));
    });

    test('nothing was measured at all', () {
      final refusal = undoCommitsRefusal(RunCommits.unread)!;
      expect(refusal, contains('has not been read'));
      expect(refusal, contains('could not take'));
    });
  });

  test('a history that has moved leaves nothing to reset back to', () {
    final refusal = undoCommitsRefusal(summary(baseSha: null))!;
    expect(refusal, contains('branch has moved'));
    expect(refusal, contains('no commit to reset back to'));
  });

  test('the checkbox leads with the count, because that is the point', () {
    expect(
      undoCommitsLabel(summary(commits: 1)),
      'Also drop the commit this run made',
    );
    expect(
      undoCommitsLabel(summary(commits: 4)),
      'Also drop the 4 commits this run made',
    );
  });

  test('restoring the files has a description and no refusal of its own', () {
    // Always offered: the base snapshot holds every byte and putting it back
    // changes nothing outside this machine.
    expect(
      undoFilesLabel(RunCommits.unread),
      contains('before this run started'),
    );
    expect(undoFilesLabel(summary(published: 2)), isNotEmpty);
  });

  test('a short sha is display only, and never a key', () {
    expect(commit('0123456789abcdef').shortSha, '0123456');
    expect(commit('abc').shortSha, 'abc');
  });
}
