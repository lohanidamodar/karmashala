import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// **"Is this a git repository?", answered off the filesystem.**
///
/// Git answers it in 132 ms; the spawn in front of it costs 90 ms locally,
/// 208–439 ms through `wsl.exe`, 17.8 s for a cold distribution. This reader
/// spends `stat`s instead, and every assertion here is about *how many* — never
/// how long, which at `--concurrency=4` would be a coin toss.
///
/// The trap it is written around is git's **parent search**: a subfolder of a
/// checkout is in a repository with no `.git` of its own, and calling that
/// untracked would be a worse bug than the one being fixed.
void main() {
  GitPresenceReader readerFor(_StatFiles files) =>
      GitPresenceReader(
        files: files,
        hostPathOf: hostPathMapperFor(windowsEnv()),
      );

  group('a Windows checkout', () {
    test('with a .git directory is a repository, from one stat', () async {
      final files = _StatFiles({r'C:\src\app\.git': PathEntry.directory});
      expect(
        await readerFor(files).read(r'C:\src\app'),
        GitPresence.repository,
      );
      expect(files.stats, [r'C:\src\app\.git']);
    });

    test('with a .git *file* is a repository too — that is a worktree', () async {
      // What git writes for a linked worktree and for a submodule. Nothing here
      // parses it: an unreadable pointer still belongs to git, not to a pane.
      final files = _StatFiles({
        r'C:\src\.karmashala-worktrees\app-s1\.git': PathEntry.file,
      });
      expect(
        await readerFor(files).read(r'C:\src\.karmashala-worktrees\app-s1'),
        GitPresence.repository,
      );
    });

    test('with nothing above it is not a repository, and never spawns', () async {
      final files = _StatFiles({
        r'C:\Users\me\notes': PathEntry.directory,
      });
      expect(
        await readerFor(files).read(r'C:\Users\me\notes'),
        GitPresence.notARepository,
      );
      // Every ancestor, and the folder itself last — that final stat is the
      // proof the filesystem was answering at all.
      expect(files.stats, [
        r'C:\Users\me\notes\.git',
        r'C:\Users\me\.git',
        r'C:\Users\.git',
        r'C:\.git',
        r'C:\Users\me\notes',
      ]);
    });
  });

  group('git searches upwards, and so does this', () {
    test('a subfolder of a checkout is in a repository', () async {
      final files = _StatFiles({r'C:\src\app\.git': PathEntry.directory});
      expect(
        await readerFor(files).read(r'C:\src\app\lib\src\features\git'),
        GitPresence.repository,
      );
      // It climbed, and stopped the moment it found one.
      expect(files.stats.last, r'C:\src\app\.git');
      expect(files.stats, isNot(contains(r'C:\.git')));
    });

    test('a POSIX subfolder of a checkout is in a repository', () async {
      final files = _StatFiles({'/home/me/app/.git': PathEntry.directory});
      final reader = GitPresenceReader(
        files: files,
        hostPathOf: hostPathMapperFor(posixEnv()),
      );
      expect(
        await reader.read('/home/me/app/lib/src'),
        GitPresence.repository,
      );
    });

    test('a WSL subfolder climbs in host spelling and stops at the share',
        () async {
      // The environment decides the path shape, never the platform (§18): a
      // WSL path is POSIX, its host spelling is a `\\wsl.localhost\…` UNC, and
      // joining the two with the wrong context builds something no `File` can
      // open.
      final files = _StatFiles({
        r'\\wsl.localhost\Ubuntu\home\me\app\.git': PathEntry.directory,
      });
      final reader = GitPresenceReader(
        files: files,
        hostPathOf: hostPathMapperFor(wslEnv()),
      );
      expect(
        await reader.read('/home/me/app/lib'),
        GitPresence.repository,
      );
      expect(files.stats.first, r'\\wsl.localhost\Ubuntu\home\me\app\lib\.git');
    });

    test('a walk that runs out at the root of a WSL share terminates',
        () async {
      final files = _StatFiles({
        r'\\wsl.localhost\Ubuntu\home\me\notes': PathEntry.directory,
      });
      final reader = GitPresenceReader(
        files: files,
        hostPathOf: hostPathMapperFor(wslEnv()),
      );
      expect(
        await reader.read('/home/me/notes'),
        GitPresence.notARepository,
      );
      // Bounded, and by the path rather than by [GitPresenceReader.maxAncestors]
      // — a runaway `dirname` would show up here as a stat count in the dozens.
      expect(files.stats.length, lessThan(8));
    });
  });

  group('what it refuses to conclude', () {
    test('a filesystem that answered nothing at all is unknown', () async {
      // Exactly what a stopped WSL distribution looks like from Windows: the
      // UNC resolves to nothing, and so does every ancestor of it. Calling that
      // "not a git repository" is the one genuinely damaging answer available
      // here.
      final files = _StatFiles(const {});
      final reader = GitPresenceReader(
        files: files,
        hostPathOf: hostPathMapperFor(wslEnv()),
      );
      expect(await reader.read('/home/me/app'), GitPresence.unknown);
    });

    test('a checkout that is a file rather than a folder is unknown', () async {
      final files = _StatFiles({r'C:\src\app': PathEntry.file});
      expect(await readerFor(files).read(r'C:\src\app'), GitPresence.unknown);
    });

    test('an SSH checkout has no local path, so it is unknown', () async {
      final files = _StatFiles(const {});
      final reader = GitPresenceReader(
        files: files,
        hostPathOf: hostPathMapperFor(sshEnvFixture()),
      );
      expect(await reader.read('/srv/app'), GitPresence.unknown);
      expect(files.stats, isEmpty, reason: 'nothing local to stat');
    });
  });

  group('gitTroubleOf reaches the same three states from git\'s refusal', () {
    // The backstop. The reader is allowed to answer `unknown` whenever it is
    // unsure, which means a pane must word a folder identically whether the
    // verdict cost zero processes or one.
    test('the reader\'s own verdict', () {
      expect(
        gitTroubleOf(
          const NotAGitRepository(
            EnvironmentPath(environmentId: 'windows', path: r'C:\notes'),
          ),
        ),
        GitTrouble.notARepository,
      );
    });

    test('git\'s parent-search refusal', () {
      expect(
        gitTroubleOf(
          GitException(
            'git status failed: fatal: not a git repository (or any of the '
            'parent directories): .git',
          ),
        ),
        GitTrouble.notARepository,
      );
    });

    test('a process that could not be started is unreachable', () {
      expect(
        gitTroubleOf(CommandException('Failed to run "git" in WSL "Ubuntu"')),
        GitTrouble.unreachable,
      );
    });

    test('a distribution that is not there is unreachable', () {
      expect(
        gitTroubleOf(
          GitException(
            'git status failed: There is no distribution with the supplied '
            'name.',
          ),
        ),
        GitTrouble.unreachable,
      );
    });

    test('anything else is a failure, and keeps git\'s words', () {
      expect(
        gitTroubleOf(
          GitException(
            'git status failed: fatal: Unable to create '
            r"'C:/src/app/.git/index.lock': File exists.",
          ),
        ),
        GitTrouble.failed,
      );
      expect(gitTroubleOf(StateError('nope')), GitTrouble.failed);
    });
  });
}

/// A filesystem that only answers `stat`, and records every one it was asked.
///
/// Anything not in the table is [PathEntry.none] — which is both "not there"
/// and "the share did not answer", exactly as `HostGitFiles` reports them.
class _StatFiles implements GitFiles {
  _StatFiles(this.entries);

  final Map<String, PathEntry> entries;
  final List<String> stats = [];

  @override
  Future<PathEntry> typeOf(String path) async {
    stats.add(path);
    return entries[path] ?? PathEntry.none;
  }

  @override
  Future<String?> readString(String path) async =>
      throw UnimplementedError('this reader never reads');

  @override
  Future<bool> exists(String path) async =>
      throw UnimplementedError('this reader never stats through exists');

  @override
  Future<void> createDirectory(String path) async =>
      throw UnimplementedError('this reader never writes');

  @override
  Future<void> writeString(String path, String contents) async =>
      throw UnimplementedError('this reader never writes');
}
