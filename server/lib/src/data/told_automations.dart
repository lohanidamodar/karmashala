import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// The automations tables written through their DAOs, each write told as the
/// row now stands — to a request's changes, or announced to every client
/// when the server writes on its own (a fire, a verdict, a check).
class ToldAutomations implements AutomationRecords {
  ToldAutomations(this._dao, this._tell);

  final AutomationDao _dao;
  final void Function(DataChange change) _tell;

  void _automation(String id) {
    final row = _dao.getById(id);
    _tell(row == null ? AutomationRemoved(id) : AutomationChanged(row));
  }

  void _run(String id) {
    final row = _dao.runById(id);
    if (row != null) _tell(AutomationRunChanged(row));
  }

  @override
  Automation? getById(String id) => _dao.getById(id);

  @override
  List<Automation> getAll() => _dao.getAll();

  @override
  List<Automation> enabled() => _dao.enabled();

  @override
  List<Automation> eventRules() => _dao.eventRules();

  @override
  void setEnabled(String id, {required bool enabled}) {
    _dao.setEnabled(id, enabled: enabled);
    _automation(id);
  }

  @override
  void recordOutcome(String id, {required bool failed}) {
    _dao.recordOutcome(id, failed: failed);
    _automation(id);
  }

  @override
  void disable(String id, String reason) {
    _dao.disable(id, reason);
    _automation(id);
  }

  @override
  void insertRun(AutomationRun run) {
    _dao.insertRun(run);
    _run(run.id);
  }

  @override
  void updateRun(AutomationRun run) {
    _dao.updateRun(run);
    _run(run.id);
  }

  @override
  AutomationRun? runById(String id) => _dao.runById(id);

  @override
  List<AutomationRun> runsFor(
    String automationId, {
    int limit = kRunsCopiedPerAutomation,
  }) => _dao.runsFor(automationId, limit: limit);

  @override
  List<AutomationRun> liveRuns() => _dao.liveRuns();

  @override
  AutomationRun? liveRunOf(String automationId) => _dao.liveRunOf(automationId);

  @override
  AutomationRun? runForSession(String sessionId) =>
      _dao.runForSession(sessionId);

  @override
  DateTime? lastFinishedAt(String automationId) =>
      _dao.lastFinishedAt(automationId);

  @override
  DateTime? lastTouchedAt(String automationId) =>
      _dao.lastTouchedAt(automationId);

  @override
  DateTime? lastObservedOccurrence(String automationId) =>
      _dao.lastObservedOccurrence(automationId);

  @override
  void insertRunCheck(AutomationCheckVerdict verdict) {
    _dao.insertRunCheck(verdict);
    _tell(AutomationRunCheckAdded(verdict));
  }

  @override
  List<AutomationCheckVerdict> checksFor(String runId) => _dao.checksFor(runId);

  @override
  void noteChecksObserved(String runId, DateTime at) {
    _dao.noteChecksObserved(runId, at);
    _run(runId);
  }

  @override
  List<String> originOfSession(String sessionId) =>
      _dao.originOfSession(sessionId);

  @override
  void markMessaged(String sessionId, List<String> origin, DateTime at) {
    _dao.markMessaged(sessionId, origin, at);
    _tell(AutomationOriginChanged(sessionId, origin));
  }

  @override
  List<String> messagedOrigin(String sessionId, {bool consume = false}) {
    final origin = _dao.messagedOrigin(sessionId, consume: consume);
    if (consume && origin.isNotEmpty) {
      _tell(AutomationOriginChanged(sessionId, const []));
    }
    return origin;
  }

  @override
  void clearMessaged(String sessionId) {
    _dao.clearMessaged(sessionId);
    _tell(AutomationOriginChanged(sessionId, const []));
  }
}

/// Armed resumes written through their DAO, each write told.
class ToldResumes implements ResumeRecords {
  ToldResumes(this._dao, this._tell);

  final ScheduledResumeDao _dao;
  final void Function(DataChange change) _tell;

  void _row(String id) {
    final row = _dao.getById(id);
    _tell(row == null ? ResumeRemoved(id) : ResumeChanged(row));
  }

  @override
  void replaceFor(ScheduledResume resume, {required DateTime now}) {
    final replaced = _dao.liveFor(resume.sessionId);
    _dao.replaceFor(resume, now: now);
    if (replaced != null) _row(replaced.id);
    _row(resume.id);
  }

  @override
  void update(ScheduledResume resume) {
    _dao.update(resume);
    _row(resume.id);
  }

  @override
  bool transition(
    String id, {
    required ScheduledResumeState from,
    required ScheduledResumeState to,
  }) {
    final moved = _dao.transition(id, from: from, to: to);
    if (moved) _row(id);
    return moved;
  }

  @override
  ScheduledResume? getById(String id) => _dao.getById(id);

  @override
  ScheduledResume? liveFor(String sessionId) => _dao.liveFor(sessionId);

  @override
  ScheduledResume? lastEndedFor(String sessionId) =>
      _dao.lastEndedFor(sessionId);

  @override
  List<ScheduledResume> live() => _dao.live();

  @override
  List<ScheduledResume> inState(ScheduledResumeState state) =>
      _dao.inState(state);

  @override
  List<ScheduledResume> recentEnded({int limit = kEndedResumesCopied}) =>
      _dao.recentEnded(limit: limit);

  @override
  void delete(String id) {
    _dao.delete(id);
    _tell(ResumeRemoved(id));
  }
}
