import '../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import '../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../explorer/application/checkout_picker.dart';
import '../git/application/changes_providers.dart';
import '../git/application/git_providers.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_git/git.dart';
import '../projects/application/projects_controller.dart';
import '../sessions/application/delivery_providers.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';

/// Making a git worktree and taking one away. Removing is not the mirror of
/// creating: [_remove] refuses unless the branch is merged **and** pushed.
class WorktreeControlTools {
  WorktreeControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{
    'worktree_create',
    'worktree_remove',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'worktree_create' => _create(
          repositoryId: args['repositoryId'] as String?,
          name: args['name'] as String?,
          branch: args['branch'] as String?,
          baseRef: args['baseRef'] as String?,
        ),
        'worktree_remove' => _remove(args['repositoryId'] as String?),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Repository _checkout(String? repositoryId, String field) {
    if (repositoryId == null || repositoryId.trim().isEmpty) {
      throw ArgumentError('$field is required. list_checkouts has the ids.');
    }
    final repository = _container
        .read(workspaceDataProvider)
        .repository(repositoryId.trim());
    if (repository == null) {
      throw StateError('No checkout with id ${repositoryId.trim()}.');
    }
    return repository;
  }

  /// Adds a worktree of [repositoryId] on a new [branch]. Collisions are checked
  /// before git runs, so a refusal names the thing in the way.
  Future<Object?> _create({
    required String? repositoryId,
    required String? name,
    required String? branch,
    required String? baseRef,
  }) async {
    final repository = _checkout(repositoryId, 'repositoryId');
    final worktreeName = _validName(name);
    final branchName = _validBranch(branch);

    final environment = _container
        .read(executionEnvironmentDaoProvider)
        .getById(repository.path.environmentId);
    if (environment == null) {
      throw StateError(
        'The environment this checkout belongs to '
        '(${repository.path.environmentId}) is no longer recorded.',
      );
    }
    final path = worktreePathFor(
      environment.kind,
      repository.path,
      worktreeName,
    );

    // Asked before git is: a plain folder has no worktrees at all, and git's
    // own refusal names a `.git` the caller never mentioned. Only observed
    // absence refuses — `unknown` (an SSH host, a stopped distro) still tries.
    final presence = await _container.read(
      checkoutGitPresenceProvider(repository.path).future,
    );
    if (presence == GitPresence.notARepository) {
      throw StateError(
        '${repository.path.path} is not a Git repository, so it has no '
        'worktrees. A session runs perfectly well in the folder itself — '
        'open_new_session without useWorktree.',
      );
    }

    final worktrees = _container.read(worktreeServiceProvider);
    final existing = await worktrees.list(repository.path);
    for (final worktree in existing) {
      if (Checkout(worktree.path) == Checkout(path)) {
        throw StateError(
          'There is already a worktree at ${path.path}'
          '${worktree.branch == null ? '' : ' (on ${worktree.branch})'}. '
          'Pick another name.',
        );
      }
      if (worktree.branch == branchName) {
        throw StateError(
          'The branch $branchName is already checked out at '
          '${worktree.path.path}. Git allows one worktree per branch, so pick '
          'another branch.',
        );
      }
    }

    // A branch that exists but is checked out nowhere: `git worktree add -b`
    // would refuse, and this says so in terms of what was asked for.
    final existingRef = await _container
        .read(changesServiceProvider)
        .revParse(repository.path, 'refs/heads/$branchName');
    if (existingRef != null) {
      throw StateError(
        'The branch $branchName already exists. This tool only ever creates a '
        'new branch, so an existing one is a refusal rather than something to '
        'check out.',
      );
    }

    final WorktreeCreationRecord stages;
    try {
      stages = (await worktrees.create(
        repo: repository.path,
        worktreeName: worktreeName,
        branch: branchName,
        baseRef: baseRef == null || baseRef.trim().isEmpty
            ? null
            : baseRef.trim(),
      )).tracker.record;
    } on GitException catch (error) {
      // Git's own words, unedited: it knows the cases we cannot check from
      // here — a directory in the way, a base ref that resolves to nothing.
      throw StateError(error.message);
    }

    return <String, Object?>{
      'fromRepositoryId': repository.id,
      'projectId': repository.projectId,
      'path': path.path,
      'environmentId': path.environmentId,
      'branch': branchName,
      'baseRef': baseRef == null || baseRef.trim().isEmpty
          ? 'not recorded — branched from the checkout\'s own HEAD'
          : baseRef.trim(),
      'repositoryId': await _recordCheckout(repository.projectId, path),
      // Each stage's state and words: a submodule or setup that needs
      // attention is here, not only in Settings.
      'stages': stages.toJson(),
    };
  }

  /// The `repositories` row for the new worktree, or why there is none: the
  /// worktree exists either way, and "not recorded" means retry the rescan.
  Future<String> _recordCheckout(String projectId, EnvironmentPath path) async {
    try {
      final added = await _container
          .read(projectsControllerProvider.notifier)
          .rediscover(projectId);
      for (final repository in added) {
        if (Checkout(repository.path) == Checkout(path)) {
          return repository.id;
        }
      }
      // Not in `added` is not the same as not recorded: a row for this path
      // could already have existed. Ask the table rather than assume.
      for (final repository
          in _container.read(workspaceDataProvider).repositoriesOf(projectId)) {
        if (Checkout(repository.path) == Checkout(path)) {
          return repository.id;
        }
      }
      return 'not recorded — the worktree is on disk, but the scan of this '
          'project did not find it. Try project_rescan.';
    } on Object {
      return 'not recorded — the worktree is on disk, but this project could '
          'not be rescanned. Try project_rescan.';
    }
  }

  /// Removes the worktree recorded as [repositoryId], or says why it will not.
  /// The branch is left alone in every case; a directory is what accumulates.
  Future<Object?> _remove(String? repositoryId) async {
    final worktree = _checkout(repositoryId, 'repositoryId');

    final labels = await _container.read(
      checkoutLabelsProvider(worktree.projectId).future,
    );
    final label = labels[worktree.id];
    if (label == null) {
      throw StateError(
        'Whether ${worktree.name} is a worktree is not recorded — git could '
        'not be asked about it. Nothing is removed on a reading Karmashala '
        'could not take.',
      );
    }
    if (!label.isWorktree) {
      throw StateError(
        '${worktree.name} is the main checkout of its repository, not a '
        'worktree. Removing a repository is not something this tool does.',
      );
    }
    final ownerId = label.ownerRepositoryId;
    final owner = ownerId == null
        ? null
        : _container.read(workspaceDataProvider).repository(ownerId);
    if (owner == null) {
      throw StateError(
        'The repository ${worktree.name} is a worktree of is not recorded, so '
        'there is nowhere to run `git worktree remove` from. Try '
        'project_rescan.',
      );
    }

    // Nothing is deleted out from under a running agent. The archive path in
    // the UI refuses on exactly this, for exactly this reason.
    final live = _liveSessionIn(worktree);
    if (live != null) {
      throw StateError(
        'The session "${live.title}" is still running in this worktree. Stop '
        'it first (session_end), then ask again.',
      );
    }

    final delivery = await _container.read(
      worktreeDeliveryProvider((
        repo: owner.path,
        worktree: worktree.path,
      )).future,
    );

    final dirty = delivery.dirtyFiles;
    if (dirty == null) {
      throw StateError(
        'The working tree of ${worktree.name} is not recorded — git status '
        'could not be read. Nothing is removed on a reading Karmashala could '
        'not take.',
      );
    }
    if (dirty > 0) {
      throw StateError(
        '$dirty uncommitted change${dirty == 1 ? '' : 's'} in '
        '${worktree.name} would be destroyed. Commit or discard them first; '
        'this tool has no way to be told to remove them.',
      );
    }

    final base = delivery.baseBranch;
    final ahead = delivery.aheadOfBase;
    if (base == null || ahead == null) {
      throw StateError(
        'Whether ${worktree.name} is merged is not recorded — '
        '${base == null ? 'no base branch could be resolved' : 'git could not '
                  'count its commits against $base'}. Nothing is removed on a '
        'reading Karmashala could not take.',
      );
    }
    if (ahead > 0) {
      throw StateError(
        '${worktree.name} has $ahead commit${ahead == 1 ? '' : 's'} that '
        '$base does not. Merge the branch first — a worktree goes only once '
        'its branch is merged and pushed.',
      );
    }

    // Merged is half the rule. Until something other than this machine holds
    // the commits, deleting the directory is still the only copy going away.
    final remotes = await _container
        .read(changesServiceProvider)
        .remoteBranchesContaining(worktree.path, 'HEAD');
    if (remotes == null) {
      throw StateError(
        'Whether ${worktree.name} is pushed is not recorded — git could not '
        'be asked which remote branches hold its commits. Nothing is removed '
        'on a reading Karmashala could not take.',
      );
    }
    if (remotes.isEmpty) {
      throw StateError(
        'No remote branch holds ${worktree.name}\'s commits, so they exist '
        'only on this machine. Push first — merged is not pushed. (Remote '
        'branches are read as of the last fetch, so `git fetch` first if it '
        'was pushed from somewhere else.)',
      );
    }

    final WorktreeTeardown? teardown;
    try {
      // No `force`, ever: every condition it would override is one this method
      // has already refused, so it could only override an unchecked one.
      teardown = await _container
          .read(worktreeServiceProvider)
          .remove(owner.path, worktree.path);
    } on GitException catch (error) {
      throw StateError(error.message);
    }

    _container.read(sessionsRevisionProvider.notifier).bump();

    return <String, Object?>{
      'repositoryId': worktree.id,
      'path': worktree.path.path,
      'branch': delivery.branch ?? 'not recorded',
      'baseBranch': base,
      'removed': true,
      'teardown': teardown?.said ?? 'none configured',
      // Both of these are deliberate, and a caller that wanted a clean sweep
      // needs to know they were not done rather than assume they were.
      'branchKept': true,
      'checkoutRecordKept': true,
      'note':
          'The directory is gone. The branch is untouched, and Karmashala '
          'still has a checkout row pointing at the old path — project_rescan '
          'retires it once nothing references it.',
    };
  }

  /// A session running in [worktree] right now, or `null`. Both ways one lands
  /// there are asked: the path on the row, and the repository id.
  Session? _liveSessionIn(Repository worktree) {
    final launcher = _container.read(sessionLauncherProvider);
    for (final session in _container.read(sessionDaoProvider).getAll()) {
      final inHere =
          session.repositoryId == worktree.id ||
          (session.worktree != null &&
              Checkout(session.worktree!) == Checkout(worktree.path));
      if (!inHere) continue;
      if (launcher.livePaneFor(session.id) != null) return session;
    }
    return null;
  }

  /// The worktree's own name, which becomes the last part of a directory name.
  String _validName(String? raw) {
    final name = raw?.trim() ?? '';
    if (name.isEmpty) {
      throw ArgumentError(
        'name is required: it becomes the folder\'s name, under '
        '.karmashala-worktrees beside the checkout.',
      );
    }
    // One path segment, never a path: a separator or a `..` in it would put the
    // worktree somewhere the caller did not ask for and this did not check.
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(name) || name.contains('..')) {
      throw ArgumentError(
        'name must be one folder name — no separators, no "..", none of '
        r'\ / : * ? " < > |. It is joined onto a directory this tool picks.',
      );
    }
    return name;
  }

  /// The new branch's name, checked against git's own ref rules.
  String _validBranch(String? raw) {
    final branch = raw?.trim() ?? '';
    if (branch.isEmpty) {
      throw ArgumentError(
        'branch is required: this tool always creates a new branch, so there '
        'is no default to fall back on.',
      );
    }
    final illegal =
        RegExp(r'[\s~^:?*\[\\]').hasMatch(branch) ||
        branch.contains('..') ||
        branch.contains('@{') ||
        branch.startsWith('-') ||
        branch.startsWith('/') ||
        branch.endsWith('/') ||
        branch.endsWith('.') ||
        branch.endsWith('.lock');
    if (illegal) {
      throw ArgumentError(
        'git will not accept "$branch" as a branch name. No whitespace, no '
        r'~ ^ : ? * [ \, no "..", and it cannot start with "-" or end with '
        '"/", "." or ".lock".',
      );
    }
    return branch;
  }
}

/// The schemas for [WorktreeControlTools].
const List<Map<String, dynamic>> worktreeControlToolSchemas = [
  {
    'name': 'worktree_create',
    'description':
        'Add a git worktree to a checkout, on a new branch, so work can run '
        'in parallel with whatever is already checked out. The folder is '
        'placed in a .karmashala-worktrees directory beside the checkout and '
        'named <checkout>-<name>. Refuses rather than colliding: a path a '
        'worktree already occupies, a branch that already exists, and a '
        'branch another worktree has out are all named back to you. The '
        'returned repositoryId reads "not recorded" when the worktree was '
        'made but Karmashala could not scan the project to record it — the '
        'folder is still there; run project_rescan.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description':
              'The checkout to make a worktree of, from list_checkouts.',
        },
        'name': {
          'type': 'string',
          'description':
              'The worktree\'s own name — one folder name, no separators.',
        },
        'branch': {
          'type': 'string',
          'description':
              'The new branch to create in it. Must not already exist.',
        },
        'baseRef': {
          'type': 'string',
          'description':
              'What to branch from (e.g. origin/main). Defaults to the '
              'checkout\'s own HEAD.',
        },
      },
      'required': ['repositoryId', 'name', 'branch'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'fromRepositoryId': {'type': 'string'},
        'projectId': {'type': 'string'},
        'path': {'type': 'string'},
        'environmentId': {'type': 'string'},
        'branch': {'type': 'string'},
        'baseRef': {'type': 'string'},
        'repositoryId': {'type': 'string'},
      },
      'required': ['path', 'branch', 'repositoryId'],
    },
  },
  {
    'name': 'worktree_remove',
    'description':
        'Delete a worktree\'s directory. Destructive and deliberately hard to '
        'get: it happens only when the worktree is clean, its branch is '
        'merged into its base, AND those commits are held by some remote '
        'branch — merged is not pushed. It also refuses while a session is '
        'running in it, and refuses on any reading Karmashala could not take '
        '("not recorded" is never read as "fine"). There is no force '
        'argument; every refusal is a sentence saying what to do instead. The '
        'branch is left alone and the checkout row stays until project_rescan '
        'retires it.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description':
              'The worktree checkout to remove, from list_checkouts. It must '
              'be one whose isWorktree is true.',
        },
      },
      'required': ['repositoryId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {'type': 'string'},
        'path': {'type': 'string'},
        'branch': {'type': 'string'},
        'baseBranch': {'type': 'string'},
        'removed': {'type': 'boolean'},
        'branchKept': {'type': 'boolean'},
        'checkoutRecordKept': {'type': 'boolean'},
        'note': {'type': 'string'},
      },
      'required': ['repositoryId', 'path', 'removed'],
    },
  },
];
