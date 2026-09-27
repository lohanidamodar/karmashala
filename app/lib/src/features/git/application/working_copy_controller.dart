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

import '../data/git_data.dart';
import 'changes_providers.dart';

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
      _run('Staging', (repo, git) => git.stage(repo, paths: paths));

  Future<void> stageAll() => _run('Staging', (repo, git) => git.stage(repo));

  Future<void> unstage(List<String> paths) =>
      _run('Unstaging', (repo, git) => git.unstage(repo, paths));

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
      (repo, git) => git.discard(repo, tracked: tracked, untracked: untracked),
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
    return _run(
      'Committing',
      (repo, git) => git.commit(repo, trimmed, all: all),
      note: 'Committed.',
    );
  }

  Future<void> fetch() =>
      _run('Fetching', (repo, git) => git.fetch(repo), note: 'Fetched.');

  Future<void> pull({bool rebase = false, bool merge = false}) => _run(
    'Pulling',
    (repo, git) => git.pull(repo, rebase: rebase, merge: merge),
    note: 'Pulled.',
  );

  /// Pushes, after the server's gitleaks scan of what it would send: a
  /// finding stops it; the note says how the scan went.
  Future<void> push() => _pushed(
    'Pushing',
    (repo, git) => git.push(repo),
    note: 'Pushed.',
  );

  /// Pushes a branch that has no upstream yet, and gives it one.
  Future<void> publish({required String branch, String remote = 'origin'}) =>
      _pushed(
        'Publishing',
        (repo, git) => git.push(repo, remote: remote, branch: branch),
        note: 'Published to $remote/$branch.',
      );

  Future<void> _pushed(
    String busy,
    Future<String> Function(EnvironmentPath repo, GitData git) push, {
    required String note,
  }) async {
    var scanned = '';
    await _run(busy, (repo, git) async {
      scanned = await push(repo, git);
    }, note: note);
    if (state.note == note && scanned.isNotEmpty) {
      state = state.copyWith(note: '$note $scanned');
    }
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
          .read(gitDataProvider)
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

  /// Runs one verb at the server: refuses while another is in flight or with
  /// nothing in view, and keeps git's own sentence when it fails.
  Future<void> _run(
    String busy,
    Future<void> Function(EnvironmentPath repo, GitData git) body, {
    String? note,
  }) async {
    if (state.isBusy) return;
    final repo = _checkout;
    if (repo == null) return;
    state = WorkingCopyState(busy: busy);
    String? failure;
    try {
      await body(repo, ref.read(gitDataProvider));
    } on GitException catch (error) {
      failure = _sentence(error.message);
    } on Object catch (error) {
      failure = _sentence('$error');
    }
    // What reads the checkout reads again when the server says it touched
    // it — the same word every other client gets.
    state = WorkingCopyState(
      error: failure,
      note: failure == null ? note : null,
    );
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
