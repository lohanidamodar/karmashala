import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/check_runner.dart'
    show CodeIdentityReader;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/store.dart';

import '../mcp/tools/checkout_delivery.dart';
import '../mcp/tools/checkout_reach.dart';

/// **One checkout's git, at the server**: a client's reads and writes of it,
/// run where its files live — reads through the runner that owns them (a WSL
/// checkout under `/mnt/<drive>` is read from Windows), writes on its own
/// environment's runner, SSH through the runners [reach] was given. Every
/// write is told as a [CheckoutTouched] through [tell].
class CheckoutGit {
  CheckoutGit({
    required this.reach,
    required RepositoryDao repositories,
    required void Function(List<DataChange> changes) tell,
    required void Function(EnvironmentPath path, String? canonicalId)
    identify,
  }) : _repositories = repositories,
       _tell = tell,
       _identifyRows = identify,
       delivery = CheckoutDeliveryReader(reach);

  final CheckoutReach reach;
  final RepositoryDao _repositories;
  final void Function(List<DataChange> changes) _tell;
  final void Function(EnvironmentPath path, String? canonicalId)
  _identifyRows;

  /// The local half of a checkout's delivery, and its pull request.
  final CheckoutDeliveryReader delivery;

  /// Where [ref] is: a recorded checkout's directory, or the directory named.
  EnvironmentPath pathOf(CheckoutRef ref) {
    final directory = ref.directory;
    if (directory != null) return directory;
    final id = ref.repositoryId!;
    return _repositories.getById(id)?.path ??
        (throw DataRefused.notFound('no checkout with id $id'));
  }

  /// A read-only question, asked where [ref]'s files are.
  Future<T> ask<T>(
    CheckoutRef ref,
    Future<T> Function(GitService git, EnvironmentPath at) question,
  ) => reach.ask(pathOf(ref), question);

  /// A write on [ref]'s own runner, told to every client afterwards — even a
  /// half-done one has changed the index or the files.
  Future<T> write<T>(
    CheckoutRef ref,
    Future<T> Function(GitService git, EnvironmentPath at) act,
  ) async {
    final path = pathOf(ref);
    try {
      return await act(reach.gitFor(path), path);
    } finally {
      touched(path, CheckoutTouchCause.gitWrite);
    }
  }

  /// Tells every client [path] may read differently now, naming the
  /// recorded checkout there when one does.
  void touched(EnvironmentPath path, CheckoutTouchCause cause) {
    final here = Checkout(path);
    final ids = [
      for (final repository in _repositories.getAll())
        if (Checkout(repository.path) == here) repository.id,
    ];
    _tell([
      if (ids.isEmpty)
        CheckoutTouched(
          environmentId: path.environmentId,
          path: path.path,
          cause: cause,
        ),
      for (final id in ids)
        CheckoutTouched(
          environmentId: path.environmentId,
          path: path.path,
          repositoryId: id,
          cause: cause,
        ),
    ]);
  }

  /// `gh` where [ref] lives.
  GitHubService gitHubFor(CheckoutRef ref) => reach.gitHubFor(pathOf(ref));

  /// How many reads run at once, across every client: a pane full of rows
  /// asks for one delivery each, and each is a handful of git processes —
  /// unbounded, twenty-eight `\\wsl.localhost` round trips were measured
  /// alive together to fill in ten branch chips.
  static const int readConcurrency = 4;

  final _slots = _Slots(readConcurrency);

  /// A read of [request]'s checkout, taking its turn among [readConcurrency].
  Future<Object?> read(CheckoutRequest<Object?> request) =>
      _slots.run(() => _read(request));

  Future<Object?> _read(CheckoutRequest<Object?> request) async {
    final at = request.checkout;
    return switch (request) {
      GitStatusOf() => ask(at, (git, p) => git.statusWithBranch(p)),
      GitChangesOf() => ask(at, (git, p) => git.status(p)),
      GitFileDiffStats() => ask(at, (git, p) => git.fileDiffStats(p)),
      GitDiff(:final path, :final staged, :final base) => ask(
        at,
        (git, p) => git.diff(p, path: path, staged: staged, base: base),
      ),
      GitDiffUntracked(:final path) => ask(at, (git, p) async {
        // A tracked file with no changes is also empty, and `--no-index`
        // would draw the whole of it as added.
        if (await git.isTracked(p, path)) return '';
        return git.diffUntracked(p, path);
      }),
      GitLog(:final limit) => ask(at, (git, p) => git.log(p, limit: limit)),
      GitBranch() => ask(at, (git, p) => git.currentBranch(p)),
      GitHead() => headOf(pathOf(at)),
      GitRevParse(:final rev) => ask(at, (git, p) => git.revParse(p, rev)),
      GitAheadBehind(:final base) => ask(
        at,
        (git, p) => git.aheadBehind(p, base: base),
      ),
      GitRemoteBranchesContaining(:final rev) => ask(
        at,
        (git, p) => git.remoteBranchesContaining(p, rev),
      ),
      GitOriginFacts() => originFacts(pathOf(at)),
      GitMergeInProgress() => mergeInProgress(pathOf(at)),
      GitBlobShas(:final paths) => ask(
        at,
        (git, p) => git.hashObjects(p, paths),
      ),
      // Its own reads, where the recorded checkout is; one with nothing
      // recorded is answered without git.
      GitCodeFreshness(:final identity) => CodeIdentityReader(
        reach.ask,
      ).freshnessOf(identity),
      GitDelivery(:final repository) => () async {
        final path = pathOf(at);
        final reading = repository == null
            ? await delivery.local(path)
            : await delivery.worktree(repository, path);
        // The one reading every checkout pays for, so the one place a
        // clone's canonical identity is kept current without a sweep.
        await _identify(repository ?? path);
        return reading;
      }(),
      _ => throw StateError('${request.kind} is not a read'),
    };
  }

  Future<Object?> writeOf(CheckoutRequest<Object?> request) async {
    final at = request.checkout;
    return switch (request) {
      GitStage(:final paths) => _ack(
        write(
          at,
          (git, p) => paths.isEmpty ? git.stageAll(p) : git.stage(p, paths),
        ),
      ),
      GitUnstage(:final paths) => _ack(
        write(at, (git, p) => git.unstage(p, paths)),
      ),
      GitDiscard(:final tracked, :final untracked) => _ack(
        write(at, (git, p) async {
          await git.discard(p, tracked);
          await git.deleteUntracked(p, untracked);
        }),
      ),
      GitCommitStaged(:final message, :final all) => _ack(
        write(at, (git, p) async {
          final trimmed = message.trim();
          if (trimmed.isEmpty) {
            throw const DataRefused.invalid('A commit needs a message.');
          }
          if (all) await git.stageAll(p);
          await git.commit(p, trimmed);
        }),
      ),
      GitFetch() => _ack(write(at, (git, p) => git.fetch(p))),
      GitPull(:final rebase, :final merge) => _ack(
        write(at, (git, p) => git.pull(p, rebase: rebase, merge: merge)),
      ),
      GitPush(:final remote, :final branch) => write(at, (git, p) async {
        // gitleaks reads the commits the push would send, where they are. A
        // finding stops it; no gitleaks lets it go, and the answer says so.
        final scan = await git.scanOutgoingSecrets(p);
        if (scan case SecretScanFound(:final findings)) {
          throw DataRefused.invalid(secretPushRefusal(findings));
        }
        await git.push(p, remote: remote, branch: branch);
        return secretScanNote(scan) ?? '';
      }),
      GitMerge(:final ref, :final commit) => _ack(
        write(
          at,
          (git, p) => commit ? git.mergeBranch(p, ref) : git.mergeRef(p, ref),
        ),
      ),
      GitAbortMerge() => write(at, (git, p) => git.abortMerge(p)),
      GitMoveBranch(:final branch, :final sha) => _ack(
        write(at, (git, p) => git.updateRef(p, 'refs/heads/$branch', sha)),
      ),
      _ => throw StateError('${request.kind} is not a write'),
    };
  }

  /// Both of `origin`'s facts from two file reads, falling back to git per
  /// fact on any uncertainty: a wrong answer is worse than a slow one.
  Future<RepositoryOrigin> originFacts(EnvironmentPath path) async {
    final reading = await GitOriginReader(
      files: reach.files,
      hostPathOf: hostPathMapperFor(_environmentOf(path)),
    ).read(path.path);
    final url = reading.url.known
        ? reading.url.value
        : await reach.ask(path, (git, at) => git.remoteUrl(at));
    if (url == null) return RepositoryOrigin.none;
    return RepositoryOrigin(
      url: url,
      head: reading.head.known
          ? reading.head.value
          : await reach.ask(path, (git, at) => git.originHead(at)),
    );
  }

  /// What [path]'s `HEAD` file names, read on this machine's own filesystem —
  /// never through a share or a runner; null for a checkout elsewhere.
  Future<String?> headOf(EnvironmentPath path) async {
    final environment = reach.environment(path.environmentId);
    final here = switch (environment?.kind) {
      EnvironmentKind.localPosix || EnvironmentKind.windowsNative =>
        reach.reaches(environment!),
      _ => false,
    };
    if (!here || path.path.startsWith(r'\\') || path.path.startsWith('//')) {
      return null;
    }
    return GitHeadReader(files: reach.files).read(path.path);
  }

  /// Whether a merge is half done, from one `.git` stat; null when this
  /// machine cannot see that filesystem.
  Future<bool?> mergeInProgress(EnvironmentPath path) => GitMergeStateReader(
    files: reach.files,
    hostPathOf: hostPathMapperFor(_environmentOf(path)),
  ).read(path.path);

  /// Which family of worktrees [path] belongs to, or null ("ask the way you
  /// used to", never "a family of one").
  Future<String?> familyKey(EnvironmentPath path) => GitOriginReader(
    files: reach.files,
    hostPathOf: hostPathMapperFor(_environmentOf(path)),
  ).commonDirectory(path.path);

  /// Records what `origin` says the clone at [path] is on the rows naming
  /// that directory — only when some row would change. Never throws.
  Future<void> _identify(EnvironmentPath path) async {
    try {
      final identity = canonicalRepositoryId((await originFacts(path)).url);
      final here = Checkout(path);
      final stale = _repositories.getAll().any(
        (row) => Checkout(row.path) == here && row.canonicalId != identity,
      );
      if (stale) _identifyRows(path, identity);
    } on Object {
      // A clone whose origin could not be read keeps what it had.
    }
  }

  ExecutionEnvironment _environmentOf(EnvironmentPath path) =>
      reach.environment(path.environmentId) ??
      (throw GitException('Unknown environment: ${path.environmentId}'));

  static Future<DataAck> _ack(Future<void> work) async {
    await work;
    return const DataAck();
  }
}

/// [error] as the refusal a client reads git's trouble back from:
/// `notFound` is not a repository, `unavailable` an environment that did
/// not answer, `failed` git's or `gh`'s own words.
DataRefused gitRefusalOf(Object error) => switch (error) {
  final DataRefused refused => refused,
  NotAGitRepository(:final directory) => DataRefused.notFound(
    '${directory.path} is not a git repository',
  ),
  CommandException(:final message) => DataRefused.unavailable(message),
  GitException(:final message) => DataRefused(DataRefusalCode.failed, message),
  GitHubException(:final message) ||
  RepositoryDiscoveryException(:final message) => DataRefused(
    DataRefusalCode.failed,
    message,
  ),
  _ => DataRefused(DataRefusalCode.failed, '$error'),
};

/// At most [concurrency] jobs at once; the rest wait their turn, first come
/// first served.
class _Slots {
  _Slots(this.concurrency);

  final int concurrency;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= concurrency) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await job();
    } finally {
      if (_waiting.isNotEmpty) {
        // The slot passes straight on, so a burst cannot slip past a job
        // that has been waiting.
        _waiting.removeAt(0).complete();
      } else {
        _running--;
      }
    }
  }
}
