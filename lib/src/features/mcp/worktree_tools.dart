import 'package:riverpod/riverpod.dart';

import '../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../explorer/application/checkout.dart';
import '../explorer/application/checkout_picker.dart';
import '../git/application/changes_providers.dart';
import '../git/application/git_providers.dart';
import 'package:karmashala_git/git.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../sessions/application/delivery_providers.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/application/session_ui_providers.dart';
import '../sessions/domain/session.dart';

/// Making a git worktree and taking one away.
///
/// `list_checkouts` and `select_checkout` could already see and point at the
/// checkouts a project has; these two are what let an agent set up a parallel
/// line of work of its own, and then clear it away.
///
/// **The two halves are not symmetrical, on purpose.** Creating one is
/// recoverable — the worst case is a folder and a branch nobody wanted, and
/// both can be deleted. Removing one is not: a worktree directory is the only
/// place some work exists until it is committed, merged and pushed, and `git
/// worktree remove` does not put it back. So [_remove] refuses in words for
/// every reading it does not like **and** for every reading it could not take,
/// and there is no argument that overrides any of it. The rule it encodes is
/// the one the owner uses by hand: a worktree goes once its branch is merged
/// **and** pushed, never on one of the two.
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
        .read(repositoryDaoProvider)
        .getById(repositoryId.trim());
    if (repository == null) {
      throw StateError('No checkout with id ${repositoryId.trim()}.');
    }
    return repository;
  }

  // --- create ---------------------------------------------------------------

  /// Adds a worktree of [repositoryId] on a new [branch].
  ///
  /// Every collision is checked *before* git runs, so a refusal names the thing
  /// in the way rather than relaying a `fatal:` about a path the caller never
  /// chose — it asked for a name, and the directory was derived from it. What
  /// this cannot check is a plain directory sitting at the computed path that
  /// is not a registered worktree; git refuses that itself, and its words are
  /// passed straight through.
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

    try {
      await worktrees.createForSession(
        repo: repository.path,
        worktreeName: worktreeName,
        branch: branchName,
        baseRef: baseRef == null || baseRef.trim().isEmpty
            ? null
            : baseRef.trim(),
      );
    } on GitException catch (error) {
      // Git's own words, unedited: it knows about the cases we cannot check
      // from here — a directory in the way, a base ref that resolves to
      // nothing, a repository in the middle of a rebase.
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
    };
  }

  /// The `repositories` row for the worktree just created, or why there is
  /// none.
  ///
  /// The worktree exists either way — git made it, and that is reported above
  /// regardless. This is the second, separable step, and it is the one that
  /// can fail on its own: discovery runs on the Windows host, so a project root
  /// on a stopped distribution or an unmounted drive cannot be scanned. Saying
  /// "not recorded" is the difference between a caller retrying the rescan and
  /// a caller believing the worktree was never made.
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
      for (final repository in _container
          .read(repositoryDaoProvider)
          .getByProject(projectId)) {
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

  // --- remove ---------------------------------------------------------------

  /// Removes the worktree recorded as [repositoryId], or says why it will not.
  ///
  /// Nine questions, and a "no" or a "could not tell" to any of them stops it.
  /// The branch is left alone in every case — a branch is cheap and
  /// recoverable, a directory is what accumulates — which is the same line
  /// `SessionArchiveService` draws for the archive button.
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
        : _container.read(repositoryDaoProvider).getById(ownerId);
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
    // the commits, deleting the directory is still the only copy going away —
    // and a branch merged into a `main` nobody has pushed is exactly that.
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

    try {
      // No `force`, ever. Every condition it would override is one this method
      // has already refused, so passing it could only ever mean overriding a
      // condition we failed to check.
      await _container
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

  /// A session running in [worktree] right now, or `null`.
  ///
  /// Two ways a session lands in one: launched with `useWorktree`, which
  /// records the path on the row, or adopted into a checkout that happens to
  /// be a worktree, which records only the repository id. Both are asked,
  /// because missing either would mean pulling the floor out from under a live
  /// agent.
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
    // One path segment, never a path. The value is joined onto a directory
    // this tool chose, and a separator or a `..` in it would put the worktree
    // somewhere the caller did not ask for and this method did not check.
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
