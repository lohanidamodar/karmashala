import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_timer.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_observer.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_runner.dart';
import 'package:karmashala/src/features/automations/data/automations_data.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AccountUsageState, UsageFailure;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../agents/usage_fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

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
    final resumed = _harness.server.sessionRows
        .getAllByExternalSessionId(request.resumeExternalSessionId!)
        .first;
    _harness.attachPane(resumed.id);
    return SessionLaunchResult(session: resumed);
  }
}

/// **The server's usage of the harness's accounts**, as a test scripts it.
///
/// The server reads usage — when the app asks (`usage.refresh`, which
/// [answer] and [failure] script) and on its own schedule ([serverRead]) —
/// and tells the app every change, which is how the scheduled-resume observer
/// hears a fresh reading. Nothing here reaches a vendor.
class ServerUsage {
  ServerUsage._(this._server, this._clock) {
    _server.agentWork.onRefresh = _read;
  }

  final FakeDataServer _server;
  final MovableClock _clock;

  /// What the server reads when asked; a fresh default reading when null.
  AgentUsage? answer;

  /// How the server's read fails instead, when set. The reading it held
  /// stays beside the failure, as the server keeps it.
  UsageException? failure;

  /// Every `usage.refresh` this app asked of the server, by account key.
  List<String?> get calls => _server.agentWork.refreshes;

  /// The server read [installation]'s account on its own schedule — [usage],
  /// or [answer] — and told every client.
  void serverRead(AgentInstallation installation, [AgentUsage? usage]) {
    if (usage != null) answer = usage;
    _server.agentWork.setUsage(
      _state(installation, usageAccountKey(installation)),
    );
  }

  AccountUsageState _read(String key) {
    final installation = _server.installationRows.getAll().firstWhere(
      (i) => usageAccountKey(i) == key,
    );
    return _state(installation, key);
  }

  AccountUsageState _state(AgentInstallation installation, String key) {
    final failed = failure;
    return AccountUsageState(
      accountKey: key,
      agentId: installation.agentId,
      environmentId: installation.environmentId,
      usage: failed == null
          ? answer ?? usageSnapshot(fetchedAt: _clock.nowUtc())
          : _server.agentWork.usage[key]?.usage,
      failure: failed == null
          ? null
          : UsageFailure(
              message: failed.message,
              kind: failed.kind,
              until: failed.retryIn == null
                  ? null
                  : _clock.nowUtc().add(failed.retryIn!),
            ),
    );
  }
}

/// Everything a scheduled-resume test needs, with nothing that waits: the
/// clock is moved and the one timer is fired by hand.
class ResumeHarness {
  ResumeHarness._(
    this.server,
    DataClient client, {
    required String agentId,
    required List<Override> extra,
  }) {
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation(agentId: agentId));
    clock = MovableClock(DateTime.utc(2026, 9, 17, 12));
    usage = ServerUsage._(server, clock);
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        dataClientProvider.overrideWithValue(client),
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

  /// The project and checkout every case works in, on a fake server whose
  /// client the container reads the workspace from.
  static Future<ResumeHarness> create({
    String agentId = AgentIds.codex,
    List<Override> extra = const [],
  }) async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    return ResumeHarness._(
      server,
      await server.connect(),
      agentId: agentId,
      extra: extra,
    );
  }

  final FakeDataServer server;
  late final MovableClock clock;
  late final ServerUsage usage;
  late final ProviderContainer container;
  final timer = ManualAutomationTimer();
  final presenter = RecordingPresenter();
  final reports = StreamController<AgentStatusReport>.broadcast();
  final Map<String, AgentStatusReport> statuses = {};
  final Map<String, List<String>> typed = {};

  DateTime get now => clock.nowUtc();

  /// This app's copy of the resumes, written through the server.
  ResumesData get dao => container.read(resumesDataProvider);
  ResumingLauncher get launcher =>
      container.read(sessionLauncherProvider) as ResumingLauncher;
  ScheduledResumeController get controller =>
      container.read(scheduledResumeControllerProvider);

  /// The server forwarded resume [id], due: this app fires it.
  Future<void> fire(String id) async {
    await settle();
    final resume = dao.getById(id);
    if (resume != null) {
      await container.read(scheduledResumeFiringProvider).fire(resume);
    }
    await settle();
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
    final dao = server.sessionRows;
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
    server.sessionRows.updatePaneId(sessionId, paneId);
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
  }
}
