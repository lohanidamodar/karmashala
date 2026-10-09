import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:crypto/crypto.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_verification/verification.dart';

/// Asks git a read-only question where [at]'s files are.
typedef GitQuestion =
    Future<T> Function<T>(
      EnvironmentPath at,
      Future<T> Function(GitService git, EnvironmentPath at) question,
    );

/// **Reads which code a checkout holds**, and holds a recorded
/// [CodeIdentity] against it. Read-only: `rev-parse`, `status`, and
/// `hash-object` without `-w` — nothing is staged, stashed or written.
class CodeIdentityReader {
  CodeIdentityReader(
    this._ask, {
    this.maxDirtyFiles = 2000,
    this.maxCountedPaths = 200,
  });

  final GitQuestion _ask;

  /// More uncommitted files than this are fingerprinted by name and status
  /// alone, and then never read as fresh — an edit inside one would not show.
  final int maxDirtyFiles;

  /// How many paths a "files changed since" count across two commits looks
  /// up; beyond it the count is left out, never guessed.
  final int maxCountedPaths;

  /// [directory]'s code now, or null when it is not a git checkout or could
  /// not be read.
  Future<CodeIdentity?> read(EnvironmentPath directory) async {
    try {
      return await _ask(directory, (git, at) => _read(git, at, directory));
    } on Object {
      return null;
    }
  }

  Future<CodeIdentity?> _read(
    GitService git,
    EnvironmentPath at,
    EnvironmentPath recordedAs,
  ) async {
    final top = await git.topLevel(at);
    if (top == null) return null;
    final root = EnvironmentPath(environmentId: at.environmentId, path: top);
    final head = await git.revParse(root, 'HEAD');
    final changes = await git.worktreeChanges(root);
    changes.sort((a, b) => a.path.compareTo(b.path));
    final complete = changes.length <= maxDirtyFiles;
    Map<String, String>? dirty;
    if (complete) {
      final present = [
        for (final c in changes)
          if (!c.deleted) c.path,
      ];
      final ids = await git.hashFiles(root, present);
      if (ids != null) {
        final hashOf = {
          for (var i = 0; i < present.length; i++) present[i]: ids[i],
        };
        dirty = {for (final c in changes) c.path: hashOf[c.path] ?? ''};
      }
    }
    final digest = sha256.convert(
      utf8.encode(
        dirty == null
            ? 'names-only\n${[for (final c in changes) '${c.path}\t${c.deleted}'].join('\n')}'
            : [
                for (final e in dirty.entries) '${e.key}\t${e.value}',
              ].join('\n'),
      ),
    );
    return CodeIdentity(
      environmentId: recordedAs.environmentId,
      path: recordedAs.path,
      head: head,
      // A names-only digest is marked, so it can never equal a full one.
      tree: dirty == null ? 'partial:$digest' : '$digest',
      dirty: dirty,
      dirtyCount: changes.length,
    );
  }

  /// [recorded] held against its checkout as it is now.
  Future<CodeFreshness> freshnessOf(CodeIdentity? recorded) async {
    if (recorded == null) return CodeFreshness.notRecorded;
    final directory = EnvironmentPath(
      environmentId: recorded.environmentId,
      path: recorded.path,
    );
    final current = await read(directory);
    if (current == null || recorded.changedDuringRun) {
      return compareCodeIdentity(recorded, current);
    }
    if (recorded.tree.startsWith('partial:') && recorded.sameCode(current)) {
      return const CodeFreshness.unknown(
        'Too many uncommitted files to fingerprint each one, so an edit '
        'inside one of them would not show: whether the code changed is '
        'unknown.',
      );
    }
    if (recorded.sameCode(current) || recorded.head == current.head) {
      return compareCodeIdentity(recorded, current);
    }
    // Two commits: what they differ in, and each one's blob for the paths
    // that matter, so the count is of files, not of commits.
    final counted = await _acrossCommits(directory, recorded, current);
    return compareCodeIdentity(
      recorded,
      current,
      committed: counted?.committed,
      recordedHeadBlobs: counted?.before,
      currentHeadBlobs: counted?.after,
    );
  }

  Future<
    ({
      Set<String> committed,
      Map<String, String> before,
      Map<String, String> after,
    })?
  >
  _acrossCommits(
    EnvironmentPath directory,
    CodeIdentity recorded,
    CodeIdentity current,
  ) async {
    final was = recorded.head;
    final now = current.head;
    if (was == null || now == null) return null;
    if (recorded.dirty == null || current.dirty == null) return null;
    try {
      return await _ask(directory, (git, at) async {
        final top = await git.topLevel(at);
        if (top == null) return null;
        final root = EnvironmentPath(
          environmentId: at.environmentId,
          path: top,
        );
        final committed = await git.pathsBetween(root, from: was, to: now);
        if (committed == null) return null;
        final paths = {
          ...committed,
          ...recorded.dirty!.keys,
          ...current.dirty!.keys,
        }.toList()..sort();
        if (paths.length > maxCountedPaths) return null;
        final before = await git.blobsAt(root, was, paths);
        final after = await git.blobsAt(root, now, paths);
        if (before == null || after == null) return null;
        return (committed: committed, before: before, after: after);
      });
    } on Object {
      return null;
    }
  }
}
