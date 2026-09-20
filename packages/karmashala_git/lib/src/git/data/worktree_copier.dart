import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../domain/worktree_setup.dart';

/// Copies one gitignored path from a checkout into a worktree beside it.
///
/// **Both ends are always in the same environment** — a worktree sits beside its
/// checkout — so this is never a transfer between machines, and a copy that runs
/// where the files are needs no environment-aware filesystem.
abstract interface class WorktreeCopier {
  /// Copies the checkout's [source] to the worktree's [destination].
  ///
  /// Never throws: a failed copy is a verdict, because the worktree exists either
  /// way and the caller has more paths to try.
  Future<WorktreeCopyVerdict> copy({
    required String path,
    required String source,
    required String destination,
  });
}

/// The copier for an environment that **is this process's own filesystem** —
/// `windowsNative` and `localPosix`, exactly the two kinds `hostPathMapperFor`
/// answers with the identity mapping.
///
/// `dart:io` rather than a `cp`/`robocopy` process: no shell to quote for, and a
/// per-file failure is reported as one. The cost is that a path longer than
/// `MAX_PATH` fails on Windows where `robocopy` would not.
class HostWorktreeCopier implements WorktreeCopier {
  const HostWorktreeCopier();

  @override
  Future<WorktreeCopyVerdict> copy({
    required String path,
    required String source,
    required String destination,
  }) async {
    WorktreeCopyVerdict verdict(WorktreeCopyResult result, String reason) =>
        WorktreeCopyVerdict(path: path, result: result, reason: reason);

    final FileSystemEntityType sourceType;
    final FileSystemEntityType destinationType;
    try {
      // Links followed on purpose: a checkout whose `node_modules` is a link is
      // asking for what it points at. *Creating* one at the destination is refused.
      sourceType = await FileSystemEntity.type(source);
      destinationType = await FileSystemEntity.type(destination);
    } on FileSystemException catch (e) {
      return verdict(
        WorktreeCopyResult.unknown,
        'Could not be looked at: ${e.osError?.message ?? e.message}. '
        'Nothing was copied on a reading that could not be taken.',
      );
    }

    if (sourceType == FileSystemEntityType.notFound) {
      return verdict(
        WorktreeCopyResult.nothingAtSource,
        'Nothing is at "$path" in the checkout, so there was nothing to copy.',
      );
    }
    if (destinationType != FileSystemEntityType.notFound) {
      return verdict(
        WorktreeCopyResult.refusedOccupied,
        'The new worktree already has something at "$path". It was left '
        'alone: a copy over it would merge two trees rather than replace one.',
      );
    }

    try {
      if (sourceType == FileSystemEntityType.directory) {
        final counted = await _copyDirectory(source, destination);
        return verdict(
          WorktreeCopyResult.copied,
          'Copied ${counted.files} file${counted.files == 1 ? '' : 's'}'
          '${counted.links == 0 ? '' : ', and left ${counted.links} symbolic '
                    'link${counted.links == 1 ? '' : 's'} uncopied'}.',
        );
      }
      await Directory(p.dirname(destination)).create(recursive: true);
      await File(source).copy(destination);
      return verdict(WorktreeCopyResult.copied, 'Copied the file.');
    } on FileSystemException catch (e) {
      return verdict(
        WorktreeCopyResult.failed,
        'Copy failed: ${e.osError?.message ?? e.message}'
        '${e.path == null ? '' : ' (${e.path})'}.',
      );
    }
  }

  /// Copies a tree, counting what it did. Links are counted, not followed:
  /// re-creating one needs a privilege Windows does not hand out by default,
  /// and following it could duplicate a tree many times over.
  Future<({int files, int links})> _copyDirectory(
    String source,
    String destination,
  ) async {
    await Directory(destination).create(recursive: true);
    var files = 0;
    var links = 0;
    await for (final entity in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: source);
      final target = p.join(destination, relative);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is Link) {
        links++;
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
        files++;
      }
    }
    return (files: files, links: links);
  }
}

/// The copier for an environment this process cannot open: a **WSL**
/// distribution or an **SSH** host. It runs `cp` *there*, through the same
/// [CommandRunner] the rest of the feature uses.
///
/// `\\wsl.localhost` is the wrong tool here: §18 measures that share at 0.79 ms
/// per listing warm, so a `.dart_tool` would be minutes of 9p round trips to do
/// what `cp -a` does inside the distribution in a second. SSH has no choice at all.
///
/// **Three or four processes per path**, at ~300 ms each on WSL, paid once per
/// worktree: each buys a refusal that would otherwise be a silent wrong answer.
class ShellWorktreeCopier implements WorktreeCopier {
  const ShellWorktreeCopier(this.runner);

  final CommandRunner runner;

  @override
  Future<WorktreeCopyVerdict> copy({
    required String path,
    required String source,
    required String destination,
  }) async {
    WorktreeCopyVerdict verdict(WorktreeCopyResult result, String reason) =>
        WorktreeCopyVerdict(path: path, result: result, reason: reason);

    final present = await _exists(source);
    if (present == null) {
      return verdict(
        WorktreeCopyResult.unknown,
        'Could not ask whether "$path" is in the checkout. Nothing was copied '
        'on a reading that could not be taken.',
      );
    }
    if (!present) {
      return verdict(
        WorktreeCopyResult.nothingAtSource,
        'Nothing is at "$path" in the checkout, so there was nothing to copy.',
      );
    }

    final occupied = await _exists(destination);
    if (occupied == null) {
      return verdict(
        WorktreeCopyResult.unknown,
        'Could not ask what is already at "$path" in the new worktree. '
        'Nothing was copied on a reading that could not be taken.',
      );
    }
    if (occupied) {
      return verdict(
        WorktreeCopyResult.refusedOccupied,
        'The new worktree already has something at "$path". It was left '
        'alone: `cp` over an existing directory merges two trees rather than '
        'replacing one.',
      );
    }

    // Only when the path is nested: an ignored parent (`build/`) exists in the
    // checkout and not in the worktree, and `cp` will not create it.
    if (path.contains('/')) {
      final made = await _run(['mkdir', '-p', p.posix.dirname(destination)]);
      if (made == null || !made.ok) {
        return verdict(
          WorktreeCopyResult.failed,
          'Could not make the folder "$path" goes in'
          '${made == null ? '' : ': ${_words(made)}'}.',
        );
      }
    }

    // `-a`: recursive, and preserving times and modes, so a copied
    // `node_modules/.bin` stays executable. No `-s`, no `ln`, and there is
    // nothing in the setting that could ask for one.
    final copied = await _run(['cp', '-a', source, destination]);
    if (copied == null) {
      return verdict(
        WorktreeCopyResult.unknown,
        'The copy of "$path" could not be started, so whether anything was '
        'written is not recorded.',
      );
    }
    return copied.ok
        ? verdict(WorktreeCopyResult.copied, 'Copied with `cp -a`.')
        : verdict(WorktreeCopyResult.failed, 'Copy failed: ${_words(copied)}');
  }

  /// Whether [path] is there — `null` when the question could not be put.
  Future<bool?> _exists(String path) async {
    final result = await _run(['test', '-e', path]);
    if (result == null) return null;
    // `test` answers 0 or 1 and nothing else; anything above that is the shell
    // failing to run it, which is not an answer about the path.
    return switch (result.exitCode) {
      0 => true,
      1 => false,
      _ => null,
    };
  }

  Future<CommandResult?> _run(List<String> argv) async {
    try {
      return await runner.run(
        CommandRequest(executable: argv.first, arguments: argv.sublist(1)),
      );
    } on CommandException {
      return null;
    }
  }

  static String _words(CommandResult result) {
    final said = result.stderr.trim().isEmpty
        ? result.stdout.trim()
        : result.stderr.trim();
    return said.isEmpty ? 'exit code ${result.exitCode}' : said;
  }
}

/// The copier for [environment], and the path context its paths are written
/// in.
///
/// The split `hostPathMapperFor` already draws: two of the four kinds *are* this
/// process's filesystem and two are not. Nothing checks `Platform.isWindows` —
/// the row decides, not the host.
({WorktreeCopier copier, p.Context context}) worktreeCopierFor(
  ExecutionEnvironment environment,
  CommandRunner runner,
) => switch (environment.kind) {
  EnvironmentKind.windowsNative => (
    copier: const HostWorktreeCopier(),
    context: p.windows,
  ),
  EnvironmentKind.localPosix => (
    copier: const HostWorktreeCopier(),
    context: p.posix,
  ),
  EnvironmentKind.wsl || EnvironmentKind.ssh => (
    copier: ShellWorktreeCopier(runner),
    context: p.posix,
  ),
};
