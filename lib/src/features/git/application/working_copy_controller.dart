/// Staging, committing and syncing the checkout the Changes pane is showing.
///
/// Karmashala has always *read* a working tree and left the writing to the
/// agent. This is the other half: the same verbs a person expects of a source
/// control pane, on the checkout already in view, on the machine that owns it.
library;

import 'package:agent_cli/process.dart';
import 'package:flutter/foundation.dart';
import 'package:karmashala_git/git.dart';
import 'package:riverpod/riverpod.dart';

import '../../github/application/github_providers.dart';
import 'changes_providers.dart';
import 'changes_service.dart';

/// What the pane is doing, and what it has to say about the last thing it did.
@immutable
class WorkingCopyState {
  const WorkingCopyState({this.busy, this.error, this.note});

  /// The verb in flight — "Committing…" — or null while nothing is.
  final String? busy;

  /// Why the last verb did not happen, in git's own words.
  final String? error;

  /// What the last verb did, when it is worth saying: "Pushed to origin/work."
  final String? note;

  bool get isBusy => busy != null;

  WorkingCopyState copyWith({
    String? busy,
    String? error,
    String? note,
    bool clear = false,
  }) => WorkingCopyState(
    busy: clear ? null : (busy ?? this.busy),
    error: clear ? null : (error ?? this.error),
    note: clear ? null : (note ?? this.note),
  );
}

/// One verb at a time against the viewed checkout. Two stagings racing would
/// interleave two `git add`s and a listing that belongs to neither.
class WorkingCopyController extends Notifier<WorkingCopyState> {
  @override
  WorkingCopyState build() => const WorkingCopyState();

  EnvironmentPath? get _checkout => ref.read(viewedCheckoutProvider);

  void dismiss() => state = const WorkingCopyState();

  Future<void> stage(List<String> paths) =>
      _run('Staging', (repo, changes) => changes.stage(repo, paths: paths));

  Future<void> stageAll() =>
      _run('Staging', (repo, changes) => changes.stage(repo));

  Future<void> unstage(List<String> paths) =>
      _run('Unstaging', (repo, changes) => changes.unstage(repo, paths));

  /// Throws the changes to [entries] away. The caller has confirmed it; this
  /// only decides which of the two acts each file needs, because an untracked
  /// file is deleted rather than rewound.
  Future<void> discard(List<FileChange> entries) {
    final tracked = [
      for (final entry in entries)
        if (entry.type != FileChangeType.untracked) entry.path,
    ];
    final untracked = [
      for (final entry in entries)
        if (entry.type == FileChangeType.untracked) entry.path,
    ];
    return _run(
      'Discarding',
      (repo, changes) =>
          changes.discard(repo, tracked: tracked, untracked: untracked),
      note: entries.length == 1
          ? 'Discarded ${entries.single.path}.'
          : 'Discarded ${entries.length} files.',
    );
  }

  /// Commits what is staged, or stages everything first when [all].
  Future<void> commit(String message, {bool all = false}) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      state = const WorkingCopyState(error: 'A commit needs a message.');
      return Future<void>.value();
    }
    return _run('Committing', (repo, changes) async {
      if (all) await changes.stage(repo);
      await changes.commit(repo, trimmed);
    }, note: 'Committed.');
  }

  Future<void> fetch() => _run(
    'Fetching',
    (repo, changes) => changes.fetch(repo),
    note: 'Fetched.',
  );

  Future<void> pull({bool rebase = false, bool merge = false}) => _run(
    'Pulling',
    (repo, changes) => changes.pull(repo, rebase: rebase, merge: merge),
    note: 'Pulled.',
  );

  Future<void> push() => _scannedPush(
    'Pushing',
    (repo, changes) => changes.push(repo),
    note: 'Pushed.',
  );

  /// Pushes a branch that has no upstream yet, and gives it one.
  Future<void> publish({required String branch, String remote = 'origin'}) =>
      _scannedPush(
        'Publishing',
        (repo, changes) => changes.push(repo, remote: remote, branch: branch),
        note: 'Published to $remote/$branch.',
      );

  /// [push], after gitleaks has read the commits it would send. A finding
  /// stops it; no gitleaks, or a scan that could not finish, lets it go and
  /// the note says the push was not checked — the tool is optional.
  Future<void> _scannedPush(
    String busy,
    Future<void> Function(EnvironmentPath repo, ChangesService changes) push, {
    required String note,
  }) async {
    var scanned = '';
    await _run(busy, (repo, changes) async {
      switch (await changes.scanOutgoingSecrets(repo)) {
        case SecretScanFound(:final findings):
          throw GitException(secretPushRefusal(findings));
        case SecretScanUnavailable():
          scanned = ' Not scanned for secrets: gitleaks is not installed.';
        case SecretScanFailed(:final reason):
          scanned = ' Not scanned for secrets: $reason.';
        case SecretScanClean():
          scanned = ' gitleaks found no secrets.';
      }
      await push(repo, changes);
    }, note: note);
    if (state.note == note) state = state.copyWith(note: '$note$scanned');
  }

  /// Opens a pull request for the checked-out branch through `gh`, and answers
  /// with its URL — the caller decides whether to open it.
  ///
  /// The one verb here that is not git: a pull request belongs to the forge,
  /// and `gh` is the only thing in this app that has ever had its credentials.
  Future<String?> createPullRequest({
    required String title,
    String body = '',
  }) async {
    if (state.isBusy) return null;
    final repo = _checkout;
    if (repo == null) return null;
    state = const WorkingCopyState(busy: 'Opening a pull request');
    try {
      final url = await ref
          .read(gitHubReviewServiceProvider)
          .createPullRequest(repo, title: title, body: body);
      state = WorkingCopyState(
        note: url.isEmpty ? 'Pull request opened.' : url,
      );
      return url;
    } on Object catch (error) {
      state = WorkingCopyState(error: _sentence('$error'));
      return null;
    }
  }

  /// Runs one verb: refuses while another is in flight or with nothing in
  /// view, keeps git's own sentence when it fails, and re-reads the listing
  /// either way — a half-done stage still changed the index.
  Future<void> _run(
    String busy,
    Future<void> Function(EnvironmentPath repo, ChangesService changes) body, {
    String? note,
  }) async {
    if (state.isBusy) return;
    final repo = _checkout;
    if (repo == null) return;
    state = WorkingCopyState(busy: busy);
    String? failure;
    try {
      await body(repo, ref.read(changesServiceProvider));
    } on GitException catch (error) {
      failure = _sentence(error.message);
    } on Object catch (error) {
      failure = _sentence('$error');
    }
    _reread();
    state = WorkingCopyState(
      error: failure,
      note: failure == null ? note : null,
    );
  }

  /// Everything that reads the working copy, after it has been written to.
  void _reread() {
    ref.invalidate(repositoryChangesProvider);
    ref.invalidate(repositoryFileDiffStatsProvider);
    ref.invalidate(workingTreeStatusProvider);
    ref.invalidate(recentCommitsProvider);
    ref.invalidate(currentBranchProvider);
  }

  /// git's failures arrive as `git commit failed: <what git said>`; the part
  /// worth showing is what git said, with its own leading `fatal:`/`error:`
  /// dropped — the pane already says something went wrong.
  static String _sentence(String message) {
    var text = message.trim();
    final colon = text.indexOf(': ');
    if (text.startsWith('git ') && colon > 0) {
      text = text.substring(colon + 2).trim();
    }
    for (final prefix in const ['fatal: ', 'error: ']) {
      if (text.toLowerCase().startsWith(prefix)) {
        text = text.substring(prefix.length);
      }
    }
    final firstLine = text.split('\n').first.trim();
    return firstLine.isEmpty ? message.trim() : firstLine;
  }
}

final workingCopyControllerProvider =
    NotifierProvider<WorkingCopyController, WorkingCopyState>(
      WorkingCopyController.new,
    );

/// Why a push was stopped, in one line: what was found and the two ways on.
String secretPushRefusal(List<SecretFinding> findings) {
  const shown = 3;
  final listed = findings.take(shown).map((f) => f.label).join(', ');
  final more = findings.length > shown
      ? ' and ${findings.length - shown} more'
      : '';
  final count = findings.length == 1
      ? 'a possible secret'
      : '${findings.length} possible secrets';
  return 'Not pushed: gitleaks found $count in commits no remote has yet — '
      '$listed$more. Take it out of those commits, or add its fingerprint to '
      '.gitleaksignore if it is not a secret.';
}
