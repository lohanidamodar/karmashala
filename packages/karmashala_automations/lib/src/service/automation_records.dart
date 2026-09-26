import '../domain/automation.dart';
import '../domain/automation_check_verdict.dart';
import '../domain/automation_run.dart';
import '../domain/project_check.dart';
import '../domain/scheduled_resume.dart';

/// The automations and their runs, checks and origin chains as the services
/// read and write them: the server's store (`AutomationDao`) or a client's
/// copy that writes through the server.
abstract interface class AutomationRecords {
  Automation? getById(String id);
  List<Automation> getAll();
  List<Automation> enabled();
  List<Automation> eventRules();
  void setEnabled(String id, {required bool enabled});
  void recordOutcome(String id, {required bool failed});
  void disable(String id, String reason);

  void insertRun(AutomationRun run);
  void updateRun(AutomationRun run);
  AutomationRun? runById(String id);
  List<AutomationRun> runsFor(String automationId, {int limit});
  List<AutomationRun> liveRuns();
  AutomationRun? liveRunOf(String automationId);
  AutomationRun? runForSession(String sessionId);
  DateTime? lastFinishedAt(String automationId);
  DateTime? lastTouchedAt(String automationId);
  DateTime? lastObservedOccurrence(String automationId);

  void insertRunCheck(AutomationCheckVerdict verdict);
  List<AutomationCheckVerdict> checksFor(String runId);
  void noteChecksObserved(String runId, DateTime at);

  List<String> originOfSession(String sessionId);
  void markMessaged(String sessionId, List<String> origin, DateTime at);
  List<String> messagedOrigin(String sessionId, {bool consume = false});
  void clearMessaged(String sessionId);
}

/// Armed resumes, one live row per session.
abstract interface class ResumeRecords {
  void replaceFor(ScheduledResume resume, {required DateTime now});
  void update(ScheduledResume resume);

  /// Moves [id] from [from] to [to]; false when it was not in [from].
  bool transition(
    String id, {
    required ScheduledResumeState from,
    required ScheduledResumeState to,
  });
  ScheduledResume? getById(String id);
  ScheduledResume? liveFor(String sessionId);
  ScheduledResume? lastEndedFor(String sessionId);
  List<ScheduledResume> live();
  List<ScheduledResume> inState(ScheduledResumeState state);
  List<ScheduledResume> recentEnded({int limit});
  void delete(String id);
}

/// A checkout's project checks and whether its verification is on.
abstract interface class ProjectCheckRecords {
  bool isVerificationEnabled(String repositoryId);
  Set<String> verifiedRepositories();
  List<ProjectCheck> forRepository(String repositoryId);
  int countFor(String repositoryId);
}
