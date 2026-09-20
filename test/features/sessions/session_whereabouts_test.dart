import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_resume_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
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

/// Captured from codex-cli 0.151.0 on 2026-09-03 by running
/// `codex --ask-for-approval untrusted --help`. `untrusted` is the value this
/// really happened to: 0.145.0 has it, 0.151.0 does not, and only the newest
/// set is declared — so an older machine gets a flag its binary refuses.
///
/// Two lines, verbatim, because the second one is where the whole message
/// lives: the CLI names the entire valid set, which is what makes a readable
/// answer possible at all.
const _rejectedValueLines = [
  "error: invalid value 'untrusted' for '--ask-for-approval "
      "<APPROVAL_POLICY>'",
  '  [possible values: on-request, never]',
];

/// The same refusal for the other axis, from `codex --sandbox bogus --help`.
const _rejectedSandboxLines = [
  "error: invalid value 'bogus' for '--sandbox <SANDBOX_MODE>'",
  '  [possible values: read-only, workspace-write, danger-full-access]',
];

/// **The pattern the app actually ships**, not a copy of it. A test that
/// declared its own regular expression would keep passing on the day the
/// declared one stopped matching, which is the only day it matters.
final _codexRejectedValue = AgentRegistry.builtIn
    .byId(AgentIds.codex)!
    .launch
    .rejectedValue;

final _exclusive = AgentDescriptor(
  id: 'exclusive',
  displayName: 'Exclusive Agent',
  binaries: const AgentBinaries(windows: ['exclusive'], posix: ['exclusive']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: const AgentResume.subcommand('resume'),
    resumeConflict: const AgentResumeConflictRules(
      markers: [GridMatcher('already has an active writer')],
    ),
    missingConversation: const AgentMissingConversationRules(
      markers: [GridMatcher('No conversation found with session ID')],
    ),
    rejectedValue: _codexRejectedValue,
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
      agentRegistryProvider.overrideWithValue(AgentRegistry([_exclusive])),
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
        ),
        externalTerminal: _fixedTerminal,
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
    // The note is the stronger claim and wins the subtitle; the reading behind
    // it is still carried, because it is what every session list orders by.
    expect(where.note, 'running here');
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

  group('a refused command-line value becomes a sentence', () {
    test("the shipped pattern reads Codex's own refusal, wrapped or not", () {
      // Unwrapped first, so a failure here is about the pattern rather than
      // about the wrapping rule.
      final plain = _codexRejectedValue.matchedBy(_rejectedValueLines)!;
      expect(plain.value, 'untrusted');
      expect(plain.flag, '--ask-for-approval');
      expect(plain.alternatives, ['on-request', 'never']);
      expect(plain.alternativesLabel, 'on-request, never');

      // And as a narrow pane renders it: every line hard-wrapped at 24
      // columns, so the wrap falls inside `--ask-for-approval` and inside
      // `on-request`. This is the case the whitespace rule exists for, and the
      // one a per-line match cannot see.
      final wrapped = _codexRejectedValue.matchedBy([
        for (final line in _rejectedValueLines) _wrapped(line, 24),
      ])!;
      expect(wrapped.value, 'untrusted');
      expect(wrapped.flag, '--ask-for-approval');
      expect(wrapped.alternatives, ['on-request', 'never']);
    });

    test('the other axis refuses in the same shape', () {
      final sandbox = _codexRejectedValue.matchedBy(_rejectedSandboxLines)!;
      expect(sandbox.value, 'bogus');
      expect(sandbox.flag, '--sandbox');
      expect(sandbox.alternatives, [
        'read-only',
        'workspace-write',
        'danger-full-access',
      ]);
    });

    test('the newest refusal wins, and ordinary output is not one', () {
      // A pane can hold more than one dead launch. The one the user just made
      // is the last, and it is the one the row has to describe.
      final twice = _codexRejectedValue.matchedBy([
        ..._rejectedSandboxLines,
        '[process exited with code 2]',
        ..._rejectedValueLines,
      ])!;
      expect(twice.value, 'untrusted');
      expect(twice.flag, '--ask-for-approval');

      expect(_codexRejectedValue.matchedBy(const []), isNull);
      expect(
        _codexRejectedValue.matchedBy(const [
          'error: invalid value',
          'Done. Bye!',
        ]),
        isNull,
      );
    });

    test('an agent whose refusal nobody has read explains nothing', () {
      // Claude Code's refusal has a different shape, and no installation here
      // has ever been seen to disagree with what is declared for it. An
      // undeclared pattern is "we cannot explain this", never a guess.
      final claude = AgentRegistry.builtIn
          .byId(AgentIds.claudeCode)!
          .launch
          .rejectedValue;
      expect(claude.isEmpty, isTrue);
      expect(claude.matchedBy(_rejectedValueLines), isNull);
    });

    test('a dead pane that never started says so, in the CLI\'s own '
        'vocabulary', () async {
      // The safety net for the permission axes being wrong about *this*
      // binary: mode support belongs to the installation, and the app declares
      // the newest set it has read. The user used to see the raw
      // `error: invalid value …` and an agent that would not start.
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final id = await launch(h.container);
      final paneId = SessionDao(h.db).getById(id)!.paneId!;
      writeToPane(
        h.container,
        paneId,
        '${[for (final line in _rejectedValueLines) _wrapped(line, 24)].join()}'
        '[process exited with code 2]\r\n',
      );
      killProcess(h.container, paneId);
      h.container.invalidate(sessionWhereaboutsProvider(id));

      final where = h.container.read(sessionWhereaboutsProvider(id));
      expect(where.rejectedValue?.value, 'untrusted');
      expect(where.note, "would not start — no 'untrusted' in this build");
      // The two things the raw stderr never told the user: which of their
      // choices was refused, and what this installation has instead.
      expect(where.explanation, contains("'untrusted'"));
      expect(where.explanation, contains('on-request, never'));
      // It died reading its command line, so it never had an opinion about the
      // conversation. Neither resume answer may be claimed from this pane.
      expect(where.refusedResume, isFalse);
      expect(where.conversationMissing, isFalse);
      expect(where.knownHeldElsewhere, isFalse);
    });
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
