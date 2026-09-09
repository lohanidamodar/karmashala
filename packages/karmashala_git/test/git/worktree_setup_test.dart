import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

void main() {
  group('a copy path is refused for a reason it can name', () {
    void refuses(String path, String because) {
      final refusal = worktreeCopyPathRefusal(path);
      expect(refusal, isNotNull, reason: '"$path" should be refused');
      expect(
        refusal!.toLowerCase(),
        contains(because),
        reason: 'the refusal has to say why: $refusal',
      );
    }

    test('blank', () => refuses('   ', 'blank'));

    test('an absolute POSIX path', () => refuses('/etc/passwd', 'absolute'));

    test('a Windows drive', () => refuses(r'C:\secrets', 'absolute'));

    test('a rooted Windows path', () => refuses(r'\secrets', 'absolute'));

    test('climbing out with ..', () => refuses('../other/.env', '..'));

    test('.. in the middle', () => refuses('build/../../x', '..'));

    test('.git itself', () => refuses('.git', 'git'));

    test('inside .git', () => refuses('.git/config', 'git'));

    // §18: the line is parsed a second time by the distribution's login shell.
    test('a space', () => refuses('macos/My Vendor', 'space'));
    test('a glob', () => refuses('build/*', 'character'));
    test('a substitution', () => refuses(r'$(id -u)', 'character'));
    test('a quote', () => refuses("a'b", 'character'));
    test('a semicolon', () => refuses('a;rm -rf b', 'character'));
    test('a newline', () => refuses('a\nb', 'character'));
    test('a backtick', () => refuses('a`b`', 'character'));

    test('the paths this repository actually needs are allowed', () {
      for (final path in [
        '.dart_tool',
        '.env',
        'macos/Vendor',
        'node_modules',
        'android/key.properties',
        'build',
        'ios/Pods',
        'local.properties',
      ]) {
        expect(
          worktreeCopyPathRefusal(path),
          isNull,
          reason: '"$path" is an ordinary gitignored path',
        );
      }
    });
  });

  group('the setting cannot ask for a symlink', () {
    // Not a preference: two live worktrees sharing one `.dart_tool` through a
    // junction corrupt each other under concurrent builds, and this app runs
    // agents concurrently by design. The enforcement is that there is nothing
    // to set — asserted here rather than left to a comment, so a "share this
    // one instead" field cannot be added without this failing.
    test('a copy path is a bare string, with no mode beside it', () {
      const setup = WorktreeSetup(copyPaths: ['.dart_tool']);
      expect(setup.copyPathsJson, '[".dart_tool"]');
      expect(
        WorktreeSetup.fromJson(null, '[{"path":".dart_tool","mode":"link"}]')
            .copyPaths,
        isEmpty,
        reason: 'a path that is not a plain string is not a path we copy',
      );
    });
  });

  group('the setting round-trips through its two JSON columns', () {
    test('a command and paths', () {
      const setup = WorktreeSetup(
        command: ['flutter', 'pub', 'get'],
        copyPaths: ['.dart_tool', 'macos/Vendor'],
      );
      expect(
        WorktreeSetup.fromJson(setup.commandJson, setup.copyPathsJson),
        setup,
      );
    });

    test('nothing at all', () {
      expect(WorktreeSetup.fromJson(null, null), const WorktreeSetup());
      expect(const WorktreeSetup().isEmpty, isTrue);
    });

    test('a row this code did not write reads as empty, never throws', () {
      expect(
        WorktreeSetup.fromJson('not json', '{"also":"not a list"}'),
        const WorktreeSetup(),
      );
    });

    test('a command is argv, so a spacey argument survives storage', () {
      const setup = WorktreeSetup(
        command: ['pwsh', '-Command', 'Write-Host "hello there"'],
      );
      final back = WorktreeSetup.fromJson(setup.commandJson, null);
      expect(back.command, hasLength(3));
      expect(back.command.last, 'Write-Host "hello there"');
    });
  });

  group('a verdict never reads better than what was observed', () {
    WorktreeCopyVerdict verdict(WorktreeCopyResult result) =>
        WorktreeCopyVerdict(path: '.dart_tool', result: result, reason: 'r');

    test('unknown needs attention — it is not success', () {
      expect(WorktreeCopyResult.unknown.needsAttention, isTrue);
      expect(
        WorktreeSetupVerdict.of([verdict(WorktreeCopyResult.unknown)], null),
        WorktreeSetupVerdict.attention,
      );
    });

    test('nothing at the source is an answer, not a problem', () {
      expect(WorktreeCopyResult.nothingAtSource.needsAttention, isFalse);
      expect(
        WorktreeSetupVerdict.of([
          verdict(WorktreeCopyResult.nothingAtSource),
        ], null),
        WorktreeSetupVerdict.ok,
      );
    });

    test('every refusal needs attention', () {
      for (final result in [
        WorktreeCopyResult.refusedTracked,
        WorktreeCopyResult.refusedPath,
        WorktreeCopyResult.refusedOccupied,
        WorktreeCopyResult.failed,
      ]) {
        expect(result.needsAttention, isTrue, reason: result.name);
      }
    });

    test('a command still running is not yet a failure', () {
      expect(WorktreeCommandResult.running.needsAttention, isFalse);
      expect(WorktreeCommandResult.notConfigured.needsAttention, isFalse);
    });

    test('nowhere visible to run it needs attention', () {
      expect(WorktreeCommandResult.refusedNoPane.needsAttention, isTrue);
      expect(WorktreeCommandResult.couldNotStart.needsAttention, isTrue);
    });

    test('a process that stopped with no code is not "succeeded"', () {
      // There is deliberately no route from a null exit code to a healthy
      // verdict. `PaneExit.exitCode` is nullable for a real reason — "we never
      // learned" — and reading a missing number as a zero is the §19 mistake.
      const started = WorktreeCommandVerdict(
        result: WorktreeCommandResult.running,
        reason: 'Running in a pane.',
        paneId: 'p1',
      );
      expect(
        started.afterExit(null).result,
        WorktreeCommandResult.stoppedWithoutCode,
      );
      expect(started.afterExit(null).exitCode, isNull);
      expect(started.afterExit(null).result.needsAttention, isTrue);
      expect(started.afterExit(0).result, WorktreeCommandResult.succeeded);
      expect(started.afterExit(2).result, WorktreeCommandResult.failed);
      expect(started.afterExit(2).reason, contains('2'));
      // The pane it ran in survives the correction — it is where the output is.
      expect(started.afterExit(2).paneId, 'p1');
    });

    test('only "running" is pending; a stopped pane is no longer tracked', () {
      expect(WorktreeCommandResult.running.isPending, isTrue);
      for (final result in WorktreeCommandResult.values) {
        if (result == WorktreeCommandResult.running) continue;
        expect(result.isPending, isFalse, reason: result.name);
      }
    });
  });

  group('a report survives storage with its age and its sentences', () {
    final ranAt = DateTime.utc(2026, 9, 8, 11, 30);

    WorktreeSetupReport report() => WorktreeSetupReport(
      repositoryId: 'r1',
      worktreePath: r'C:\src\.karmashala-worktrees\app-s1',
      environmentId: 'windows',
      ranAt: ranAt,
      copies: const [
        WorktreeCopyVerdict(
          path: '.dart_tool',
          result: WorktreeCopyResult.copied,
          reason: 'Copied 412 files.',
        ),
        WorktreeCopyVerdict(
          path: 'lib',
          result: WorktreeCopyResult.refusedTracked,
          reason: '"lib" $worktreeCopyNotIgnored',
        ),
      ],
      command: const WorktreeCommandVerdict(
        result: WorktreeCommandResult.failed,
        reason: 'Exited with code 1.',
        command: ['flutter', 'pub', 'get'],
        paneId: 'pane-7',
        exitCode: 1,
      ),
    );

    test('the verdict is attention when any half needs it', () {
      expect(report().verdict, WorktreeSetupVerdict.attention);
      expect(report().problems.map((v) => v.path), ['lib']);
    });

    test('round-trips', () {
      final stored = report().toJsonString();
      final back = WorktreeSetupReport.fromStored(
        repositoryId: 'r1',
        worktreePath: r'C:\src\.karmashala-worktrees\app-s1',
        environmentId: 'windows',
        ranAt: ranAt,
        detail: stored,
      );
      expect(back.ranAt, ranAt);
      expect(back.copies, hasLength(2));
      expect(back.copies.last.result, WorktreeCopyResult.refusedTracked);
      expect(back.copies.last.reason, contains('not ignored by git'));
      expect(back.command!.exitCode, 1);
      expect(back.command!.command, ['flutter', 'pub', 'get']);
      expect(back.verdict, WorktreeSetupVerdict.attention);
    });

    test('unreadable detail reads as an empty report, never throws', () {
      final back = WorktreeSetupReport.fromStored(
        repositoryId: 'r1',
        worktreePath: '/x',
        environmentId: 'e',
        ranAt: ranAt,
        detail: 'nonsense{',
      );
      expect(back.copies, isEmpty);
      expect(back.command, isNull);
    });
  });

  group('a typed command line becomes argv, once, visibly', () {
    test('plain words', () {
      expect(splitCommandLine('flutter pub get'), ['flutter', 'pub', 'get']);
      expect(splitCommandLine('  make   setup  '), ['make', 'setup']);
      expect(splitCommandLine(''), isEmpty);
      expect(splitCommandLine('   '), isEmpty);
    });

    test('quotes group, and the quotes themselves are dropped', () {
      expect(splitCommandLine('pwsh -Command "Write-Host a b"'), [
        'pwsh',
        '-Command',
        'Write-Host a b',
      ]);
      expect(splitCommandLine("sh -c 'echo a b'"), ['sh', '-c', 'echo a b']);
      expect(splitCommandLine('--message="two words"'), [
        '--message=two words',
      ]);
    });

    test('an empty quoted argument is still an argument', () {
      expect(splitCommandLine('--flag ""'), ['--flag', '']);
    });

    // The classic bug this parser is written to avoid: a Windows path is full
    // of backslashes, and treating them as escapes eats them.
    test('a backslash is a character, never an escape', () {
      expect(splitCommandLine(r'C:\src\app\tool.exe --out C:\build'), [
        r'C:\src\app\tool.exe',
        '--out',
        r'C:\build',
      ]);
    });

    test('nothing is expanded — that belongs to the shell the pane opens', () {
      expect(splitCommandLine(r'echo $HOME %PATH% *.dart'), [
        'echo',
        r'$HOME',
        '%PATH%',
        '*.dart',
      ]);
    });

    test('a round-trip through the editor never splits an argument', () {
      for (final argv in [
        ['flutter', 'pub', 'get'],
        ['pwsh', '-Command', 'Write-Host two words'],
        [r'C:\src\app\tool.exe', '--out', r'C:\build'],
        ['sh', '-c', "echo 'quoted inside'"],
        ['--flag', ''],
      ]) {
        expect(
          splitCommandLine(joinCommandLine(argv)),
          argv,
          reason: joinCommandLine(argv),
        );
      }
    });
  });
}
