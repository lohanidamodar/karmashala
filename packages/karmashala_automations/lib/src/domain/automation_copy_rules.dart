import '../service/automation_records.dart';
import 'automation.dart';
import 'automation_check_verdict.dart';
import 'automation_run.dart';
import 'project_check.dart';
import 'scheduled_resume.dart';

/// The newest runs of each automation a client's copy holds — what the page
/// shows. Live runs are always held, however old.
const int kRunsCopiedPerAutomation = 50;

/// The newest ended resumes a copy holds beside each session's last one.
const int kEndedResumesCopied = 20;

// The tables' orders, for a copy that answers what the DAOs answer.

int compareAutomations(Automation a, Automation b) {
  final byName = a.name.compareTo(b.name);
  return byName != 0 ? byName : a.id.compareTo(b.id);
}

/// Newest due first (`runsFor`).
int compareRunsNewestFirst(AutomationRun a, AutomationRun b) {
  final due = b.scheduledFor.compareTo(a.scheduledFor);
  return due != 0 ? due : b.firedAt.compareTo(a.firedAt);
}

/// Oldest due first — the order a queue drains in (`liveRuns`).
int compareRunsDueFirst(AutomationRun a, AutomationRun b) =>
    compareRunsNewestFirst(b, a);

/// Soonest first (`live`, `inState`).
int compareResumesSoonest(ScheduledResume a, ScheduledResume b) {
  final at = a.fireAt.compareTo(b.fireAt);
  return at != 0 ? at : a.scheduledAt.compareTo(b.scheduledAt);
}

/// Newest ending first (`recentEnded`, `lastEndedFor`).
int compareResumesEndedNewest(ScheduledResume a, ScheduledResume b) =>
    (b.finishedAt ?? b.fireAt).compareTo(a.finishedAt ?? a.fireAt);

int compareProjectChecks(ProjectCheck a, ProjectCheck b) {
  final at = a.createdAt.compareTo(b.createdAt);
  return at != 0 ? at : a.id.compareTo(b.id);
}

/// What [AutomationRecords] answers, over a copy of the rows: every
/// automation, the runs held (see [kRunsCopiedPerAutomation]), their checks
/// and the origin chains messages left.
abstract class AutomationCopyReads implements AutomationRecords {
  Iterable<Automation> get automationRows;
  Iterable<AutomationRun> get runRows;
  List<AutomationCheckVerdict>? checkRows(String runId);
  List<String>? originRow(String sessionId);

  AutomationRun? runRow(String id);
  Automation? automationRow(String id);

  @override
  Automation? getById(String id) => automationRow(id);

  @override
  List<Automation> getAll() => [...automationRows]..sort(compareAutomations);

  @override
  List<Automation> enabled() => [
    for (final a in getAll())
      if (a.enabled) a,
  ];

  @override
  List<Automation> eventRules() => [
    for (final a in getAll())
      if (a.isEventDriven) a,
  ];

  @override
  AutomationRun? runById(String id) => runRow(id);

  @override
  List<AutomationRun> runsFor(
    String automationId, {
    int limit = kRunsCopiedPerAutomation,
  }) => ([
    for (final r in runRows)
      if (r.automationId == automationId) r,
  ]..sort(compareRunsNewestFirst)).take(limit).toList();

  @override
  List<AutomationRun> liveRuns() => [
    for (final r in runRows)
      if (r.state.isLive) r,
  ]..sort(compareRunsDueFirst);

  @override
  AutomationRun? liveRunOf(String automationId) {
    for (final run in liveRuns()) {
      if (run.automationId == automationId) return run;
    }
    return null;
  }

  @override
  AutomationRun? runForSession(String sessionId) {
    AutomationRun? newest;
    for (final r in runRows) {
      if (r.sessionId != sessionId) continue;
      if (newest == null || r.firedAt.isAfter(newest.firedAt)) newest = r;
    }
    return newest;
  }

  DateTime? _latest(
    String automationId,
    DateTime? Function(AutomationRun run) pick,
  ) {
    DateTime? latest;
    for (final r in runRows) {
      if (r.automationId != automationId) continue;
      final at = pick(r);
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }

  @override
  DateTime? lastFinishedAt(String automationId) =>
      _latest(automationId, (r) => r.finishedAt);

  @override
  DateTime? lastTouchedAt(String automationId) =>
      _latest(automationId, (r) => r.firedAt);

  @override
  DateTime? lastObservedOccurrence(String automationId) =>
      _latest(automationId, (r) => r.scheduledFor);

  @override
  List<AutomationCheckVerdict> checksFor(String runId) =>
      [...?checkRows(runId)]..sort((a, b) => a.ordinal.compareTo(b.ordinal));

  @override
  List<String> originOfSession(String sessionId) {
    final run = runForSession(sessionId);
    if (run == null) return const [];
    return run.origin.isEmpty ? [run.automationId] : run.origin;
  }
}

/// What [ResumeRecords] answers over a copy of the resumes.
abstract class ResumeCopyReads implements ResumeRecords {
  Iterable<ScheduledResume> get resumeRows;
  ScheduledResume? resumeRow(String id);

  @override
  ScheduledResume? getById(String id) => resumeRow(id);

  @override
  ScheduledResume? liveFor(String sessionId) {
    for (final r in resumeRows) {
      if (r.sessionId == sessionId && r.state.isLive) return r;
    }
    return null;
  }

  @override
  ScheduledResume? lastEndedFor(String sessionId) {
    final ended = [
      for (final r in resumeRows)
        if (r.sessionId == sessionId && !r.state.isLive) r,
    ]..sort(compareResumesEndedNewest);
    return ended.firstOrNull;
  }

  @override
  List<ScheduledResume> live() => [
    for (final r in resumeRows)
      if (r.state.isLive) r,
  ]..sort(compareResumesSoonest);

  @override
  List<ScheduledResume> inState(ScheduledResumeState state) => [
    for (final r in resumeRows)
      if (r.state == state) r,
  ]..sort(compareResumesSoonest);

  @override
  List<ScheduledResume> recentEnded({int limit = kEndedResumesCopied}) => ([
    for (final r in resumeRows)
      if (!r.state.isLive) r,
  ]..sort(compareResumesEndedNewest)).take(limit).toList();
}

/// What [ProjectCheckRecords] answers over a copy of the checks.
abstract class ProjectCheckCopyReads implements ProjectCheckRecords {
  Iterable<ProjectCheck> get checkRowsAll;
  Set<String> get verifiedRows;

  @override
  bool isVerificationEnabled(String repositoryId) =>
      verifiedRows.contains(repositoryId);

  @override
  Set<String> verifiedRepositories() => {...verifiedRows};

  @override
  List<ProjectCheck> forRepository(String repositoryId) => [
    for (final c in checkRowsAll)
      if (c.repositoryId == repositoryId) c,
  ]..sort(compareProjectChecks);

  @override
  int countFor(String repositoryId) => forRepository(repositoryId).length;
}
