import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_resume_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import '../../support/fake_command_runner.dart';

/// Captured from codex-cli 0.151.0 on 2026-08-30, by holding thread
/// `01a051ab-…` open in one process and resuming it in a second (which exited
/// 1). Verbatim, because the point of the matcher is that it survives this
/// sentence being wrapped, and a paraphrase would not be the same sentence.
const _refusal =
    'Error: Failed to resume session from /home/dlohani/.codex/sessions/2026/'
    '08/30/rollout-2026-08-30T13-41-56-01a051ab-eaeb-7a73-b8a4-a27d81e47984'
    '.jsonl: thread/resume failed during TUI bootstrap: thread/resume failed: '
    'thread 01a051ab-eaeb-7a73-b8a4-a27d81e47984 already has an active writer '
    '(code -32600)';

/// Captured from the owner's own pane on 2026-09-01, after the app resumed a
/// session id it had assigned to a conversation Claude Code never wrote.
const _noSuchConversation =
    'No conversation found with session ID: '
    '4b13c55e-ec74-4c0b-ac63-44747861aabd';

const _exclusive = AgentDescriptor(
  id: 'exclusive',
  displayName: 'Exclusive Agent',
  binaries: AgentBinaries(windows: ['exclusive'], posix: ['exclusive']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.subcommand('resume'),
    resumeConflict: AgentResumeConflictRules(
      markers: [GridMatcher('already has an active writer')],
    ),
    missingConversation: AgentMissingConversationRules(
      markers: [GridMatcher('No conversation found with session ID')],
    ),
  ),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

({ProviderContainer container, AppDatabase db}) harness() {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: 'exclusive'));

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      // Never shell out: an external launch must not open a real terminal.
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([_exclusive]),
      ),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
    ],
  );
  return (container: container, db: db);
}

const _fixedTerminal = SystemTerminal(
  kind: SystemTerminalKind.windowsTerminal,
  label: 'Windows Terminal',
  executable: 'wt.exe',
);

Future<String> launch(
  ProviderContainer container, {
  SessionSurface surface = SessionSurface.pane,
}) async {
  final launched = await container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: 'exclusive'),
          title: 'Work',
          purpose: SessionPurpose.newSession,
          surface: surface,
          externalTerminal: _fixedTerminal,
        ),
      );
  return launched.session.id;
}

/// Kills the process behind [paneId] without taking the pane down with it, so
/// its last words stay on screen — which is exactly the state a refused resume
/// leaves behind.
void killProcess(ProviderContainer container, String paneId) {
  final instance =
      container
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId)!
          as FakeTerminalInstance;
  instance.livenessNotifier.value = PaneLiveness.exited;
}

/// [text] as a pane of [columns] columns would have wrapped it. Every character
/// survives; only line breaks are added.
String _wrapped(String text, int columns) {
  final lines = <String>[];
  for (var i = 0; i < text.length; i += columns) {
    lines.add(text.substring(i, (i + columns).clamp(0, text.length)));
  }
  return '${lines.join('\r\n')}\r\n';
}

void writeToPane(ProviderContainer container, String paneId, String text) {
  container
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId)!
      .terminal
      .write(text);
}

void main() {
  test('a live pane of ours is the one thing we can be certain of', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final id = await launch(h.container);
    final where = h.container.read(sessionWhereaboutsProvider(id));

    expect(where.hostedLive, isTrue);
    expect(where.note, 'running here');
    // We can see the process, so an age would only dilute a stronger claim.
    expect(where.lastSeenLabel(testTime), isNull);
  });

  test('a dead pane showing the agent\'s refusal is proof of a holder', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final id = await launch(h.container);
    final paneId = SessionDao(h.db).getById(id)!.paneId!;
    // The refusal as a narrow pane renders it: hard-wrapped, and the wrap falls
    // inside a word — the case a per-line substring match cannot see.
    writeToPane(h.container, paneId, _wrapped(_refusal, 24));
    killProcess(h.container, paneId);
    h.container.invalidate(sessionWhereaboutsProvider(id));

    final where = h.container.read(sessionWhereaboutsProvider(id));
    expect(where.hostedLive, isFalse);
    expect(where.refusedResume, isTrue);
    expect(where.knownHeldElsewhere, isTrue);
    expect(where.note, 'open in another process');
  });

  test('a dead pane with ordinary output claims nothing', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final id = await launch(h.container);
    final paneId = SessionDao(h.db).getById(id)!.paneId!;
    writeToPane(h.container, paneId, 'Done. Bye!\r\n');
    killProcess(h.container, paneId);
    h.container.invalidate(sessionWhereaboutsProvider(id));

    final where = h.container.read(sessionWhereaboutsProvider(id));
    expect(where.refusedResume, isFalse);
    expect(where.knownHeldElsewhere, isFalse);
    expect(where.note, isNull);
  });

  test('an external surface is a record, never a claim', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    // No pane: it was handed to a terminal window we do not own.
    final id = await launch(h.container, surface: SessionSurface.external);
    final where = h.container.read(sessionWhereaboutsProvider(id));

    expect(where.external, isTrue);
    expect(where.note, 'opened in an external terminal');
    // The whole point: "we started a window once" never becomes "it is running".
    expect(where.knownHeldElsewhere, isFalse);
    expect(where.hostedLive, isFalse);
  });

  test('a session we know nothing about says nothing', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final where = h.container.read(sessionWhereaboutsProvider('no-such-thing'));
    expect(where.note, isNull);
    expect(where.explanation, isNull);
    expect(where.lastSeen, isNull);
  });

  test('the refusal only counts for an agent that declares it', () async {
    // An agent whose refusal we have never seen cannot be explained, and an
    // unexplained dead pane must not be dressed up as one that was refused.
    const undeclared = AgentDescriptor(
      id: 'exclusive',
      displayName: 'Exclusive Agent',
      binaries: AgentBinaries(windows: ['exclusive'], posix: ['exclusive']),
      launch: AgentLaunchSpec(
        interactiveResume: AgentResume.subcommand('resume'),
      ),
    );
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'exclusive'));
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // Never shell out: an external launch must not open a real terminal.
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(
          const AgentRegistry([undeclared]),
        ),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
      ],
    );
    addTearDown(db.close);
    addTearDown(container.dispose);

    final id = await launch(container);
    final paneId = SessionDao(db).getById(id)!.paneId!;
    writeToPane(container, paneId, _refusal);
    killProcess(container, paneId);
    container.invalidate(sessionWhereaboutsProvider(id));

    expect(
      container.read(sessionWhereaboutsProvider(id)).refusedResume,
      isFalse,
    );
  });

  test("a dead pane saying the agent has no record of the conversation says "
      'so, and does not claim a holder', () async {
    // The fallback for a resume the store probe could not predict. The user
    // saw this exact pane and read it as lost work; the row now carries the
    // agent's own answer instead of still saying "running here".
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final id = await launch(h.container);
    final paneId = SessionDao(h.db).getById(id)!.paneId!;
    writeToPane(
      h.container,
      paneId,
      '${_wrapped(_noSuchConversation, 20)}[process exited with code 1]\r\n',
    );
    killProcess(h.container, paneId);
    h.container.invalidate(sessionWhereaboutsProvider(id));

    final where = h.container.read(sessionWhereaboutsProvider(id));
    expect(where.conversationMissing, isTrue);
    expect(where.note, 'no conversation to resume');
    expect(where.explanation, contains('no record of it'));
    // The opposite of a holder. Folding the two together would block a resume
    // that should be explained instead.
    expect(where.refusedResume, isFalse);
    expect(where.knownHeldElsewhere, isFalse);
  });

  test('an agent that has never said it counts for nothing', () async {
    const undeclared = AgentDescriptor(
      id: 'exclusive',
      displayName: 'Exclusive Agent',
      binaries: AgentBinaries(windows: ['exclusive'], posix: ['exclusive']),
      launch: AgentLaunchSpec(
        interactiveResume: AgentResume.subcommand('resume'),
      ),
    );
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'exclusive'));
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(
          const AgentRegistry([undeclared]),
        ),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
      ],
    );
    addTearDown(db.close);
    addTearDown(container.dispose);

    final id = await launch(container);
    final paneId = SessionDao(db).getById(id)!.paneId!;
    writeToPane(container, paneId, _noSuchConversation);
    killProcess(container, paneId);
    container.invalidate(sessionWhereaboutsProvider(id));

    expect(
      container.read(sessionWhereaboutsProvider(id)).conversationMissing,
      isFalse,
    );
  });

  test('a restored pane is never read for either answer', () async {
    // A pane rebuilt from disk holds the *previous* run's output, so an answer
    // in there is not evidence about this one — and reading it would build the
    // buffer the restore deliberately kept unparsed.
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);

    final id = await launch(h.container);
    final paneId = SessionDao(h.db).getById(id)!.paneId!;
    writeToPane(h.container, paneId, _noSuchConversation);
    final instance =
        h.container
                .read(terminalSessionsControllerProvider.notifier)
                .instanceFor(paneId)!
            as FakeTerminalInstance;
    instance.livenessNotifier.value = PaneLiveness.restored;
    h.container.invalidate(sessionWhereaboutsProvider(id));

    final where = h.container.read(sessionWhereaboutsProvider(id));
    expect(where.conversationMissing, isFalse);
    expect(where.refusedResume, isFalse);
  });

  test('a status with no source contributes no age', () {
    // `AgentStatusSource.none` means "nothing could tell us anything". Its
    // observedAt is the poll's own clock, which is always fresh — rendering it
    // as a last-seen would put a live-looking timestamp on a session nobody has
    // any evidence about at all.
    final report = AgentStatusReport(
      agentId: 'exclusive',
      sessionId: 's1',
      status: AgentActivityStatus.unknown,
      source: AgentStatusSource.none,
      observedAt: testTime,
    );
    expect(report.evidenceAt, testTime);
    // A source that *can* date its evidence reports the file, not the poll.
    final dated = AgentStatusReport(
      agentId: 'exclusive',
      sessionId: 's1',
      status: AgentActivityStatus.idle,
      source: AgentStatusSource.stateFile,
      observedAt: testTime,
      sourceModifiedAt: testTime.subtract(const Duration(days: 2)),
    );
    expect(dated.evidenceAt, testTime.subtract(const Duration(days: 2)));
  });
}
