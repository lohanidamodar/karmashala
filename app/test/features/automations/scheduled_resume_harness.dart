import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/automations/application/automation_scheduler.dart';
import 'package:karmashala/src/features/automations/application/automation_timer.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_observer.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../agents/usage_fixtures.dart';
import '../terminal/fake_instance.dart';

/// Records what would have reached the OS.
class RecordingPresenter implements NotificationPresenter {
  final List<NotificationRequest> shown = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> show(NotificationRequest request) async => shown.add(request);

  @override
  void dispose() {}
}

/// A launcher whose resume opens a fake pane for the session, as the real one
/// would, and starts nothing.
class ResumingLauncher extends SessionLauncher {
  ResumingLauncher(super.ref, this._harness);

  final ResumeHarness _harness;
  final List<SessionLaunchRequest> requests = [];
  Object? failure;

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    requests.add(request);
    final failed = failure;
    if (failed != null) throw failed;
    final resumed = SessionDao(
      _harness.db,
    ).getAllByExternalSessionId(request.resumeExternalSessionId!).first;
    _harness.attachPane(resumed.id);
    return SessionLaunchResult(session: resumed);
  }
}

/// Everything a scheduled-resume test needs, with nothing that waits: the
/// clock is moved and the one timer is fired by hand.
class ResumeHarness {
  ResumeHarness({
    String agentId = AgentIds.codex,
    List<Override> extra = const [],
  }) {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: agentId));
    clock = MovableClock(DateTime.utc(2026, 9, 17, 12));
    usage = FakeAgentUsageService(clock: clock);
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db, usageService: usage),
        clockProvider.overrideWithValue(clock),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('resume-')),
        automationTimerProvider.overrideWithValue(timer),
        notificationPresenterProvider.overrideWithValue(presenter),
        sessionLauncherProvider.overrideWith(
          (ref) => ResumingLauncher(ref, this),
        ),
        sessionStatusLookupProvider.overrideWithValue((id) => statuses[id]),
        sessionStatusStreamProvider.overrideWithValue((_) => reports.stream),
        ...extra,
      ],
    );
  }

  late final AppDatabase db;
  late final MovableClock clock;
  late final FakeAgentUsageService usage;
  late final ProviderContainer container;
  final timer = ManualAutomationTimer();
  final presenter = RecordingPresenter();
  final reports = StreamController<AgentStatusReport>.broadcast();
  final Map<String, AgentStatusReport> statuses = {};
  final Map<String, List<String>> typed = {};

  DateTime get now => clock.nowUtc();
  ScheduledResumeDao get dao => ScheduledResumeDao(db);
  ResumingLauncher get launcher =>
      container.read(sessionLauncherProvider) as ResumingLauncher;
  ScheduledResumeController get controller =>
      container.read(scheduledResumeControllerProvider);

  /// Watched, not read: an unwatched scheduler disarms itself (Riverpod 3).
  AutomationScheduler scheduler() {
    container.listen(automationSchedulerProvider, (_, _) {});
    return container.read(automationSchedulerProvider.notifier);
  }

  void observe() =>
      container.listen(scheduledResumeObserverProvider, (_, _) {});

  /// A session that can be resumed unattended: it has a conversation, and a
  /// mode that does not prompt.
  void addSession({
    String id = 's1',
    String title = 'Work',
    String? permissionMode = 'approval=never;sandbox=danger-full-access',
    String repositoryId = 'r1',
  }) {
    final dao = SessionDao(db);
    dao.insert(session(id: id, title: title, repositoryId: repositoryId));
    dao.updateExternalSessionId(id, 'conv-$id');
    dao.updatePermissionMode(id, permissionMode);
  }

  /// Gives [sessionId] a live pane, and records what is typed into it.
  String attachPane(String sessionId) {
    final panes = container.read(terminalSessionsControllerProvider.notifier);
    panes.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .last
        .layout
        .panes
        .first;
    SessionDao(db).updatePaneId(sessionId, paneId);
    panes.instanceFor(paneId)!.terminal.onOutput = (data) =>
        typed.putIfAbsent(sessionId, () => []).add(data);
    return paneId;
  }

  /// What was typed into [sessionId], joined — text, end-of-line key, return.
  String typedInto(String sessionId) => (typed[sessionId] ?? const []).join();

  AgentStatusReport report(
    String sessionId, {
    AgentActivityStatus status = AgentActivityStatus.idle,
    AgentStatusSource source = AgentStatusSource.terminalGrid,
    AgentWaitKind waiting = AgentWaitKind.unrecorded,
    DateTime? observedAt,
  }) => AgentStatusReport(
    agentId: AgentIds.codex,
    sessionId: sessionId,
    status: status,
    observedAt: observedAt ?? now,
    source: source,
    waiting: waiting,
  );

  /// A reading whose 5-hour window is at [percent] and resets [resetsIn] from
  /// now.
  AgentUsage reading({
    double percent = 100,
    Duration resetsIn = const Duration(hours: 1),
    String? email = 'owner@example.com',
  }) => usageSnapshot(
    percent: percent,
    fetchedAt: now,
    resetsIn: resetsIn,
    email: email,
  );

  ScheduledResume? live(String sessionId) => dao.liveFor(sessionId);

  /// Lets queued microtasks and stream events run. No time passes.
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> dispose() async {
    await reports.close();
    container.dispose();
    db.close();
  }
}
