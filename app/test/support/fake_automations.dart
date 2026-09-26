part of 'fake_data_server.dart';

/// The automations domain of a [FakeDataServer], shaped like the server's
/// DAOs (`AutomationDao`, `ScheduledResumeDao`, `ProjectCheckDao`) and read by
/// the same rules a client's copy uses. A write here after a client connected
/// reaches it as the server's own change — a fire, a verdict, a resume.
class FakeAutomationRows extends AutomationCopyReads {
  FakeAutomationRows._(this._server);

  final FakeDataServer _server;
  final rules = <String, Automation>{};
  final runs = <String, AutomationRun>{};
  final checks = <String, List<AutomationCheckVerdict>>{};
  final origins = <String, List<String>>{};

  /// How many times a client's write would have woken the server's
  /// scheduler.
  var written = 0;

  /// What the server's scheduler does with an event run queued while its
  /// checkout is free: start it. Unset, it stays queued.
  void Function(AutomationRun queued)? startQueued;

  void _tell(DataChange change) => _server._tell(null, [change]);

  @override
  Iterable<Automation> get automationRows => rules.values;
  @override
  Iterable<AutomationRun> get runRows => runs.values;
  @override
  Automation? automationRow(String id) => rules[id];
  @override
  AutomationRun? runRow(String id) => runs[id];
  @override
  List<AutomationCheckVerdict>? checkRows(String runId) => checks[runId];
  @override
  List<String>? originRow(String sessionId) => origins[sessionId];

  void insert(Automation automation) => _tell(_put(automation));

  void update(Automation automation) => insert(automation);

  void delete(String id) => _tell(_remove(id));

  AutomationChanged _put(Automation automation) {
    rules[automation.id] = automation;
    return AutomationChanged(automation);
  }

  AutomationRemoved _remove(String id) {
    rules.remove(id);
    for (final run in [...runs.values]) {
      if (run.automationId == id) {
        runs.remove(run.id);
        checks.remove(run.id);
      }
    }
    return AutomationRemoved(id);
  }

  Automation _changed(String id, Automation Function(Automation) change) {
    final row = rules[id] ?? (throw DataRefused.notFound('no automation $id'));
    return (rules[id] = change(row));
  }

  @override
  void setEnabled(String id, {required bool enabled}) => _tell(
    AutomationChanged(_changed(id, (a) => a.copyWith(enabled: enabled))),
  );

  @override
  void recordOutcome(String id, {required bool failed}) => _tell(
    AutomationChanged(_changed(id, (a) => _outcome(a, failed: failed))),
  );

  static Automation _outcome(Automation a, {required bool failed}) => failed
      ? a.copyWith(consecutiveFailures: a.consecutiveFailures + 1)
      : a.copyWith(consecutiveFailures: 0, clearDisabledReason: true);

  @override
  void disable(String id, String reason) => _tell(
    AutomationChanged(
      _changed(id, (a) => a.copyWith(enabled: false, disabledReason: reason)),
    ),
  );

  @override
  void insertRun(AutomationRun run) {
    runs[run.id] = run;
    _tell(AutomationRunChanged(run));
  }

  @override
  void updateRun(AutomationRun run) => insertRun(run);

  @override
  void insertRunCheck(AutomationCheckVerdict verdict) {
    checks[verdict.runId] = [...?checks[verdict.runId], verdict];
    _tell(AutomationRunCheckAdded(verdict));
  }

  @override
  void noteChecksObserved(String runId, DateTime at) {
    final run = runs[runId];
    if (run != null) insertRun(run.copyWith(checksObservedAt: at));
  }

  @override
  void markMessaged(String sessionId, List<String> origin, DateTime at) {
    origins[sessionId] = origin;
    _tell(AutomationOriginChanged(sessionId, origin));
  }

  @override
  List<String> messagedOrigin(String sessionId, {bool consume = false}) {
    final origin = origins[sessionId] ?? const [];
    if (consume) clearMessaged(sessionId);
    return origin;
  }

  @override
  void clearMessaged(String sessionId) {
    origins.remove(sessionId);
    _tell(AutomationOriginChanged(sessionId, const []));
  }

  AutomationsSnapshot _snapshot() => AutomationsSnapshot(
    automations: getAll(),
    runs: [...runs.values],
    checks: {
      for (final e in checks.entries) e.key: [...e.value],
    },
    origins: {
      for (final e in origins.entries) e.key: [...e.value],
    },
    projectChecks: _server.projectCheckRows.all(),
    verified: {..._server.projectCheckRows.verified},
    resumes: [..._server.resumeRows.rows.values],
  );

  Object? _handle(
    AutomationsRequest<Object?> request,
    List<DataChange> changes,
  ) {
    if (request is AutomationsList) return _snapshot();
    // Writes a client asks for are told to it in the answer, not here.
    final told = _Recording(this, changes);
    final result = switch (request) {
      AutomationsList() => _snapshot(),
      AutomationSave(:final automation) => _save(automation, changes),
      AutomationSetEnabled(:final id, :final enabled) => told.run(
        () => setEnabled(id, enabled: enabled),
        () => rules[id]!,
      ),
      AutomationDelete(:final id) => _delete(id, changes),
      AutomationRecordOutcome(:final id, :final failed) => told.run(
        () => recordOutcome(id, failed: failed),
        () => rules[id]!,
      ),
      AutomationDisable(:final id, :final reason) => told.run(
        () => disable(id, reason),
        () => rules[id]!,
      ),
      AutomationRunPut(:final run) => told.run(() {
        _rule(run.automationId);
        insertRun(run);
        return null;
      }, () => runs[run.id]!),
      AutomationEventRunQueue(:final run) => () {
        final queued =
            told.run(
                  () => queueEventRunIn(this, _rule(run.automationId), run),
                  null,
                )!
                as AutomationRun;
        final start = startQueued;
        if (start != null && queued.state == AutomationRunState.queued) {
          // After the answer, as the server's drain runs after the write.
          scheduleMicrotask(() => start(queued));
        }
        return queued;
      }(),
      AutomationRunCheckAdd(:final verdict) => told.run(
        () => insertRunCheck(verdict),
        () => const DataAck(),
      ),
      AutomationRunChecksObserved(:final runId, :final at) => told.run(
        () => noteChecksObserved(runId, at),
        () => runs[runId] ?? (throw DataRefused.notFound('no run $runId')),
      ),
      AutomationOriginMark(:final sessionId, :final origin) => told.run(
        () => markMessaged(sessionId, origin, _server._now()),
        () => const DataAck(),
      ),
      AutomationOriginClear(:final sessionId) => told.run(
        () => clearMessaged(sessionId),
        () => const DataAck(),
      ),
      ProjectCheckAdd() || ProjectCheckDelete() || ProjectVerificationSet() =>
        _server.projectCheckRows._handle(request, changes),
      ResumeSchedule() ||
      ResumeUpdate() ||
      ResumeTransition() ||
      ResumeDelete() => _server.resumeRows._handle(request, changes),
    };
    if (changes.isNotEmpty) written++;
    return result;
  }

  /// Another client's [change], into the rows alone.
  void _apply(AutomationsChange change) {
    switch (change) {
      case AutomationChanged(:final automation):
        rules[automation.id] = automation;
      case AutomationRemoved(:final id):
        _remove(id);
      case AutomationRunChanged(:final run):
        runs[run.id] = run;
      case AutomationRunCheckAdded(:final verdict):
        checks[verdict.runId] = [...?checks[verdict.runId], verdict];
      case AutomationOriginChanged(:final sessionId, :final origin):
        origin.isEmpty
            ? origins.remove(sessionId)
            : origins[sessionId] = origin;
      case ProjectCheckChanged(:final check):
        _server.projectCheckRows.rows[check.id] = check;
      case ProjectCheckRemoved(:final id):
        _server.projectCheckRows.rows.remove(id);
      case ProjectVerificationChanged(:final repositoryId, :final enabled):
        enabled
            ? _server.projectCheckRows.verified.add(repositoryId)
            : _server.projectCheckRows.verified.remove(repositoryId);
      case ResumeChanged(:final resume):
        _server.resumeRows.rows[resume.id] = resume;
      case ResumeRemoved(:final id):
        _server.resumeRows.rows.remove(id);
    }
  }

  Automation _rule(String id) =>
      rules[id] ?? (throw DataRefused.notFound('no automation with id $id'));

  Automation _save(Automation automation, List<DataChange> changes) {
    if (automation.name.trim().isEmpty) {
      throw const DataRefused.invalid('An automation needs a name.');
    }
    changes.add(_put(automation));
    return automation;
  }

  DataAck _delete(String id, List<DataChange> changes) {
    _rule(id);
    changes.add(_remove(id));
    return const DataAck();
  }
}

/// Routes the rows' own tells into a request's changes while it runs.
class _Recording {
  _Recording(this._rows, this._changes);

  final FakeAutomationRows _rows;
  final List<DataChange> _changes;

  Object? run(Object? Function() write, Object? Function()? answer) {
    final server = _rows._server;
    final before = server._recordInto;
    server._recordInto = _changes;
    try {
      final written = write();
      return answer == null ? written : answer();
    } finally {
      server._recordInto = before;
    }
  }
}

/// Scheduled resumes of a [FakeDataServer], shaped like `ScheduledResumeDao`.
class FakeResumeRows extends ResumeCopyReads {
  FakeResumeRows._(this._server);

  final FakeDataServer _server;
  final rows = <String, ScheduledResume>{};

  @override
  Iterable<ScheduledResume> get resumeRows => rows.values;
  @override
  ScheduledResume? resumeRow(String id) => rows[id];

  void _put(ScheduledResume resume) {
    rows[resume.id] = resume;
    _server._tell(null, [ResumeChanged(resume)]);
  }

  @override
  void replaceFor(ScheduledResume resume, {required DateTime now}) {
    final live = liveFor(resume.sessionId);
    if (live != null) {
      _put(
        live.copyWith(
          state: ScheduledResumeState.cancelled,
          reason: 'Replaced by a newer schedule.',
          finishedAt: now,
        ),
      );
    }
    _put(resume);
  }

  @override
  void update(ScheduledResume resume) => _put(resume);

  @override
  bool transition(
    String id, {
    required ScheduledResumeState from,
    required ScheduledResumeState to,
  }) {
    final row = rows[id];
    if (row == null || row.state != from) return false;
    _put(row.copyWith(state: to));
    return true;
  }

  @override
  void delete(String id) {
    rows.remove(id);
    _server._tell(null, [ResumeRemoved(id)]);
  }

  Object? _handle(
    AutomationsRequest<Object?> request,
    List<DataChange> changes,
  ) {
    final before = _server._recordInto;
    _server._recordInto = changes;
    try {
      return switch (request) {
        ResumeSchedule(:final resume) => () {
          replaceFor(resume, now: _server._now());
          return resume;
        }(),
        ResumeUpdate(:final resume) => () {
          if (rows[resume.id] == null) {
            throw DataRefused.notFound('no scheduled resume ${resume.id}');
          }
          update(resume);
          return resume;
        }(),
        ResumeTransition(:final id, :final from, :final to) => transition(
          id,
          from: from,
          to: to,
        ),
        ResumeDelete(:final id) => () {
          delete(id);
          return const DataAck();
        }(),
        _ => throw StateError('not a resume request: $request'),
      };
    } finally {
      _server._recordInto = before;
    }
  }
}

/// Project checks and verification switches of a [FakeDataServer], shaped
/// like `ProjectCheckDao`.
class FakeProjectCheckRows extends ProjectCheckCopyReads {
  FakeProjectCheckRows._(this._server);

  final FakeDataServer _server;
  final rows = <String, ProjectCheck>{};
  final verified = <String>{};

  @override
  Iterable<ProjectCheck> get checkRowsAll => rows.values;
  @override
  Set<String> get verifiedRows => verified;

  List<ProjectCheck> all() => [...rows.values]..sort(compareProjectChecks);

  void insert(ProjectCheck check) {
    rows[check.id] = check;
    _server._tell(null, [ProjectCheckChanged(check)]);
  }

  void delete(String id) {
    rows.remove(id);
    _server._tell(null, [ProjectCheckRemoved(id)]);
  }

  void setVerificationEnabled(String repositoryId, {required bool enabled}) {
    enabled ? verified.add(repositoryId) : verified.remove(repositoryId);
    _server._tell(null, [
      ProjectVerificationChanged(repositoryId, enabled: enabled),
    ]);
  }

  Object? _handle(
    AutomationsRequest<Object?> request,
    List<DataChange> changes,
  ) {
    final before = _server._recordInto;
    _server._recordInto = changes;
    try {
      return switch (request) {
        ProjectCheckAdd(:final check) => () {
          final problem =
              projectCheckNameRefusal(check.name) ??
              projectCheckCommandRefusal(check.command);
          if (problem != null) throw DataRefused.invalid(problem);
          insert(check);
          return check;
        }(),
        ProjectCheckDelete(:final id) => () {
          delete(id);
          return const DataAck();
        }(),
        ProjectVerificationSet(:final repositoryId, :final enabled) => () {
          setVerificationEnabled(repositoryId, enabled: enabled);
          return const DataAck();
        }(),
        _ => throw StateError('not a project check request: $request'),
      };
    } finally {
      _server._recordInto = before;
    }
  }
}
