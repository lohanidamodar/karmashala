import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

/// A row's title — the words the panel and the agent tools both say.
void main() {
  Checkpoint checkpoint({
    CheckpointReason reason = CheckpointReason.turn,
    int? turn = 3,
    String? prompt,
    String? label,
    List<String> files = const ['a.dart', 'b.dart'],
  }) => Checkpoint(
    id: 'c1',
    sessionId: 's1',
    repository: const EnvironmentPath(environmentId: 'local', path: '/app'),
    sequence: 7,
    treeSha: 't',
    commitSha: 'c',
    parentCommitSha: null,
    headSha: null,
    reason: reason,
    createdAt: DateTime.utc(2026, 9, 27),
    turn: turn,
    prompt: prompt,
    label: label,
    files: [
      for (final f in files)
        FileChange(
          path: f,
          type: FileChangeType.modified,
          staged: false,
          unstaged: true,
        ),
    ],
  );

  test('a turn is titled by what it was asked, both sides of it', () {
    const prompt = 'Fix the login redirect loop';
    expect(
      checkpointTitle(
        checkpoint(reason: CheckpointReason.turnStart, prompt: prompt),
      ),
      'Before: Fix the login redirect loop',
    );
    expect(
      checkpointTitle(checkpoint(prompt: prompt)),
      'After: Fix the login redirect loop',
    );
  });

  test('a prompt becomes one short line, not a paste', () {
    String title(String prompt) => checkpointTitle(checkpoint(prompt: prompt));
    expect(
      title(
        '```\nStackTrace at main.dart:12\n```\n'
        '## Fix the crash when sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef '
        'is set\nand run the tests\n\nLogs follow: a b c',
      ),
      'After: Fix the crash when … is set and run the tests',
    );
    final long = title('word ' * 40);
    expect(long.length, lessThanOrEqualTo('After: '.length + 72));
    expect(long, endsWith('word…'));
    expect(title('   \n```\nonly code\n```'), 'After: a.dart, b.dart');
  });

  test('with no prompt: the files after a turn, the number before one', () {
    expect(checkpointTitle(checkpoint()), 'After: a.dart, b.dart');
    expect(
      checkpointTitle(
        checkpoint(files: const ['lib/a.dart', 'b.dart', 'c.dart', 'd.dart']),
      ),
      'After: a.dart, b.dart and 2 more',
    );
    expect(
      checkpointTitle(checkpoint(reason: CheckpointReason.turnStart)),
      'Before turn 3',
    );
    expect(checkpointTitle(checkpoint(files: const [])), 'After turn 3');
    expect(checkpointTitle(checkpoint(turn: null, files: const [])), 'Turn #7');
    expect(
      checkpointTitle(checkpoint(reason: CheckpointReason.safety)),
      'Before restore #7',
    );
    expect(
      checkpointTitle(checkpoint(reason: CheckpointReason.manual)),
      'Checkpoint #7',
    );
  });

  test('an unverified before-turn keeps its warning under any title', () {
    expect(lateTurnStartLabel(3), 'Before turn 3 — $kUnverifiedBeforeNote');
    final marked = checkpoint(
      reason: CheckpointReason.turnStart,
      prompt: 'Change the app',
      label: lateTurnStartLabel(3),
    );
    expect(isUnverifiedBefore(marked), isTrue);
    expect(
      checkpointTitle(marked),
      'Before: Change the app — may already include its first edit',
    );
    expect(
      checkpointTitle(
        checkpoint(reason: CheckpointReason.turnStart, label: 'anything'),
      ),
      'Before turn 3 — may already include its first edit',
    );
    expect(
      checkpointTitle(
        checkpoint(
          reason: CheckpointReason.turnStart,
          prompt: 'word ' * 40,
          label: lateTurnStartLabel(3),
        ),
      ),
      endsWith('… — may already include its first edit'),
    );
    final named = checkpoint(
      reason: CheckpointReason.manual,
      label: 'Before deploy',
    );
    expect(isUnverifiedBefore(named), isFalse);
    expect(checkpointTitle(named), 'Before deploy');
  });

  test('the words a panel shows for a capture or a skip', () {
    expect(kNothingToCapture, contains('Nothing has changed'));
    expect(kNothingToCapture, contains('no repository to checkpoint'));
    expect(
      kAutomaticCheckpointsOff,
      startsWith('automatic checkpoints are off'),
    );
  });
}
