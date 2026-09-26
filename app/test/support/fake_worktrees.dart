part of 'fake_data_server.dart';

/// The git side tables of a [FakeDataServer]: each checkout's worktree setup,
/// every worktree's setup verdict and the review threads, shaped like the
/// server's DAOs. A write here after a client connected reaches it as the
/// server's own change.
class FakeWorktreeRows {
  FakeWorktreeRows._(this._server);

  final FakeDataServer _server;
  final setups = <String, WorktreeSetup>{};
  final runs = <String, WorktreeSetupReport>{};
  final threads = <String, ReviewThread>{};
  var _commentIds = 0;

  WorktreeSetup get(String repositoryId) =>
      setups[repositoryId] ?? const WorktreeSetup();

  Map<String, WorktreeSetup> getAll() => Map.of(setups);

  List<WorktreeSetupReport> runsFor(String repositoryId) => [
    for (final run in runs.values)
      if (run.repositoryId == repositoryId) run,
  ]..sort(compareSetupRuns);

  WorktreeSetupReport? lastRun(String repositoryId, EnvironmentPath worktree) =>
      runs['$repositoryId\n${worktree.path}'];

  void save(String repositoryId, WorktreeSetup setup) =>
      _server._tell(null, [_save(repositoryId, setup)]);

  void record(WorktreeSetupReport report) =>
      _server._tell(null, [_record(report)]);

  void putThread(ReviewThread thread) {
    threads[thread.id] = thread;
    _server._tell(null, [ReviewThreadChanged(thread)]);
  }

  WorktreeSetupChanged _save(String repositoryId, WorktreeSetup setup) {
    setup.isEmpty ? setups.remove(repositoryId) : setups[repositoryId] = setup;
    return WorktreeSetupChanged(repositoryId, setups[repositoryId]);
  }

  WorktreeRunRecorded _record(WorktreeSetupReport report) {
    runs[report.key] = report;
    return WorktreeRunRecorded(report);
  }

  ReviewThread _thread(String id) =>
      threads[id] ?? (throw DataRefused.notFound('no review thread $id'));

  ReviewThread _changed(ReviewThread thread, List<DataChange> changes) {
    threads[thread.id] = thread;
    changes.add(ReviewThreadChanged(thread));
    return thread;
  }

  ReviewComment _comment(
    String threadId,
    int sequence,
    String author,
    ReviewAuthorKind kind,
    String body,
  ) => ReviewComment(
    id: ++_commentIds,
    threadId: threadId,
    sequence: sequence,
    author: author,
    authorKind: kind,
    body: body,
    createdAt: _server._now(),
  );

  Object? _handle(WorktreesRequest<Object?> request, List<DataChange> changes) {
    String body(String text) =>
        reviewBodyOf(text) ??
        (throw const DataRefused.invalid('A review comment needs a body.'));
    return switch (request) {
      WorktreesList() => WorktreesSnapshot(
        setups: getAll(),
        runs: [...runs.values],
        threads: [...threads.values],
      ),
      WorktreeSetupSave(:final repositoryId, :final setup) => () {
        changes.add(_save(repositoryId, setup));
        return const DataAck();
      }(),
      WorktreeSetupClear(:final repositoryId) => () {
        changes.add(_save(repositoryId, const WorktreeSetup()));
        return const DataAck();
      }(),
      WorktreeSetupRecord(:final report) => () {
        changes.add(_record(report));
        return const DataAck();
      }(),
      final ReviewThreadOpen r => () {
        if (threads.containsKey(r.id)) {
          throw DataRefused.invalid('a thread with id ${r.id} exists');
        }
        final start = r.anchor.startLine;
        final now = _server._now();
        return _changed(
          ReviewThread(
            id: r.id,
            repositoryId: r.repositoryId,
            anchor: ReviewAnchor(
              path: r.anchor.path,
              blobSha: r.anchor.blobSha,
              startLine: start,
              endLine: start == null ? null : (r.anchor.endLine ?? start),
              excerpt: r.anchor.excerpt,
            ),
            status: r.status ?? defaultReviewStatus(r.authorKind),
            sessionId: r.sessionId,
            createdAt: now,
            updatedAt: now,
            comments: [_comment(r.id, 1, r.author, r.authorKind, body(r.body))],
          ),
          changes,
        );
      }(),
      final ReviewThreadReply r => () {
        final thread = _thread(r.threadId);
        return _changed(
          thread.copyWith(
            updatedAt: _server._now(),
            comments: [
              ...thread.comments,
              _comment(
                r.threadId,
                thread.comments.length + 1,
                r.author,
                r.authorKind,
                body(r.body),
              ),
            ],
          ),
          changes,
        );
      }(),
      ReviewThreadSetStatus(:final threadId, :final status) => _changed(
        _thread(threadId).copyWith(status: status, updatedAt: _server._now()),
        changes,
      ),
    };
  }

  /// The schema's cascade from checkouts [ids] going, as the server tells it.
  void _checkoutsGoing(Set<String> ids, List<DataChange> changes) {
    for (final id in ids) {
      if (setups.remove(id) != null) {
        changes.add(WorktreeSetupChanged(id, null));
      }
    }
    for (final run in [...runs.values]) {
      if (!ids.contains(run.repositoryId)) continue;
      runs.remove(run.key);
      changes.add(WorktreeRunRemoved(run.key));
    }
    for (final thread in [...threads.values]) {
      if (!ids.contains(thread.repositoryId)) continue;
      threads.remove(thread.id);
      changes.add(ReviewThreadRemoved(thread.id));
    }
  }

  void _apply(WorktreesChange change) {
    switch (change) {
      case WorktreeSetupChanged(:final repositoryId, :final setup):
        _save(repositoryId, setup ?? const WorktreeSetup());
      case WorktreeRunRecorded(:final report):
        _record(report);
      case ReviewThreadChanged(:final thread):
        threads[thread.id] = thread;
      case WorktreeRunRemoved(:final key):
        runs.remove(key);
      case ReviewThreadRemoved(:final id):
        threads.remove(id);
    }
  }
}

/// The command snippets and saved presets of a [FakeDataServer].
class FakeSnippetRows {
  FakeSnippetRows._(this._server);

  final FakeDataServer _server;
  final snippets = <String, CommandSnippet>{};
  final presets = <String, StoredPreset>{};

  List<CommandSnippet> list() => [...snippets.values]..sort(compareSnippets);

  CommandSnippet? getById(String id) => snippets[id];

  List<StoredPreset> presetsNow() => [...presets.values]..sort(comparePresets);

  void insert(CommandSnippet snippet) {
    snippets[snippet.id] = snippet;
    _server._tell(null, [SnippetChanged(snippet)]);
  }

  void savePreset(StoredPreset preset) {
    presets[preset.id] = preset;
    _server._tell(null, [PresetChanged(preset)]);
  }

  CommandSnippet _changed(CommandSnippet snippet, List<DataChange> changes) {
    snippets[snippet.id] = snippet;
    changes.add(SnippetChanged(snippet));
    return snippet;
  }

  Object? _handle(SnippetsRequest<Object?> request, List<DataChange> changes) {
    void check(String label, String command) {
      final problem = snippetProblem(label: label, command: command);
      if (problem != null) throw DataRefused.invalid(problem);
    }

    return switch (request) {
      SnippetsList() => SnippetsSnapshot(
        snippets: list(),
        presets: presetsNow(),
      ),
      final SnippetAdd r => () {
        check(r.label, r.command);
        if (snippets.containsKey(r.id)) {
          throw DataRefused.invalid('a snippet with id ${r.id} exists');
        }
        final now = _server._now();
        return _changed(
          CommandSnippet(
            id: r.id,
            label: r.label.trim(),
            command: singleLine(r.command),
            shellId: r.shellId,
            submit: r.submit,
            createdAt: now,
            updatedAt: now,
          ),
          changes,
        );
      }(),
      final SnippetEdit r => () {
        check(r.label, r.command);
        final existing =
            snippets[r.id] ??
            (throw DataRefused.notFound('no snippet with id ${r.id}'));
        return _changed(
          existing.copyWith(
            label: r.label.trim(),
            command: singleLine(r.command),
            shellId: r.shellId,
            clearShell: r.shellId == null,
            submit: r.submit,
            updatedAt: _server._now(),
          ),
          changes,
        );
      }(),
      SnippetDelete(:final id) => () {
        if (snippets.remove(id) != null) changes.add(SnippetRemoved(id));
        return const DataAck();
      }(),
      final PresetSave r => () {
        final name = r.presetName.trim();
        if (name.isEmpty) {
          throw const DataRefused.invalid('A preset needs a name.');
        }
        final preset = StoredPreset(
          id: presetIdFor(name, r.id, presets.values),
          name: name,
          shape: r.shape,
          updatedAt: _server._now(),
        );
        presets[preset.id] = preset;
        changes.add(PresetChanged(preset));
        return preset;
      }(),
      PresetDelete(:final id) => () {
        if (presets.remove(id) != null) changes.add(PresetRemoved(id));
        return const DataAck();
      }(),
    };
  }

  void _apply(SnippetsChange change) {
    switch (change) {
      case SnippetChanged(:final snippet):
        snippets[snippet.id] = snippet;
      case SnippetRemoved(:final id):
        snippets.remove(id);
      case PresetChanged(:final preset):
        presets[preset.id] = preset;
      case PresetRemoved(:final id):
        presets.remove(id);
    }
  }
}
