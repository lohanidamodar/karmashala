import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_liveness_reconciler.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:logging/logging.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';

/// **The two refusals this has actually cost us**, verbatim from the two Codex
/// builds on the owner's machine. One flag, two versions, opposite directions:
/// 0.145.0 has `untrusted` and no `on-failure`, so a launch carrying
/// `on-failure` is refused; 0.151.0 dropped `untrusted`, so a launch carrying
/// *that* is refused. Both name the whole valid set, which is the property the
/// parser is built on.
const _refusedOnFailure = [
  "error: invalid value 'on-failure' for '--ask-for-approval "
      "<APPROVAL_POLICY>'",
  '  [possible values: untrusted, on-request, never]',
];

const _refusedUntrusted = [
  "error: invalid value 'untrusted' for '--ask-for-approval "
      "<APPROVAL_POLICY>'",
  '  [possible values: on-request, never]',
];

/// The pattern the app ships, not a copy of it: a test with its own regular
/// expression keeps passing on the one day the declared one stops matching.
final _codexRules = AgentRegistry.builtIn
    .byId(AgentIds.codex)!
    .launch
    .rejectedValue;

final _codex = AgentDescriptor(
  id: 'codex-under-test',
  displayName: 'Codex',
  binaries: const AgentBinaries(windows: ['codex'], posix: ['codex']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    rejectedValue: _codexRules,
  ),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

Future<({ProviderContainer container, AppDatabase db, FakeDataServer server})>
harness() async {
  final db = AppDatabase.memory();
  final server = FakeDataServer()..mirrorInto(db);
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  AgentInstallationDao(db).insert(agentInstallation(agentId: _codex.id));

  final container = ProviderContainer(
    overrides: [
      await server.override(),
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        AgentRegistry([DataOnlyAgentAdapter(_codex)]),
      ),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
    ],
  );
  return (container: container, db: db, server: server);
}

/// [text] as a pane of [columns] columns would have wrapped it: every character
/// survives, only line breaks are added.
String _wrapped(String text, int columns) {
  final lines = <String>[];
  for (var i = 0; i < text.length; i += columns) {
    lines.add(text.substring(i, (i + columns).clamp(0, text.length)));
  }
  return '${lines.join('\r\n')}\r\n';
}

Future<({String id, String pane})> _launch(
  ProviderContainer container,
  AppDatabase db,
) async {
  final launched = await container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: agentInstallation(agentId: _codex.id),
          title: 'Work',
          purpose: SessionPurpose.newSession,
        ),
      );
  return (
    id: launched.session.id,
    pane: SessionDao(db).getById(launched.session.id)!.paneId!,
  );
}

void _writeToPane(ProviderContainer container, String paneId, String text) {
  container
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId)!
      .terminal
      .write(text);
}

/// Kills the process behind [paneId] without taking the pane down with it, so
/// its last words stay on screen — the state a refused command line leaves.
void _killProcess(ProviderContainer container, String paneId) {
  final instance =
      container
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId)!
          as FakeTerminalInstance;
  instance.livenessNotifier.value = PaneLiveness.exited;
}

/// Captures what the app logs for the duration of a test, the way
/// `session_launcher_test.dart` does.
List<LogRecord> _captureLogs() {
  final previous = Diagnostics.instance;
  final records = <LogRecord>[];
  Diagnostics.instance = Diagnostics(echoToConsole: false);
  AppLogger.initialize(onRecord: records.add);
  addTearDown(() {
    Diagnostics.instance = previous;
    AppLogger.initialize();
  });
  return records;
}

void main() {
  group('the parser reads both refusals this has cost us', () {
    test('0.145.0 refusing on-failure', () {
      final rejected = _codexRules.matchedBy(_refusedOnFailure)!;
      expect(rejected.value, 'on-failure');
      expect(rejected.flag, '--ask-for-approval');
      expect(rejected.alternatives, ['untrusted', 'on-request', 'never']);
      expect(rejected.alternativesLabel, 'untrusted, on-request, never');
    });

    test('0.151.0 refusing untrusted', () {
      final rejected = _codexRules.matchedBy(_refusedUntrusted)!;
      expect(rejected.value, 'untrusted');
      expect(rejected.flag, '--ask-for-approval');
      expect(rejected.alternatives, ['on-request', 'never']);
    });

    test('and both as a narrow pane holds them', () {
      // 24 columns puts the wrap inside `--ask-for-approval` and inside the
      // value — the case a per-line match cannot see.
      for (final lines in [_refusedOnFailure, _refusedUntrusted]) {
        final rejected = _codexRules.matchedBy([
          for (final line in lines) _wrapped(line, 24),
        ]);
        expect(rejected, isNotNull, reason: lines.first);
        expect(rejected!.flag, '--ask-for-approval');
        expect(rejected.alternatives, isNotEmpty);
      }
    });

    test('the sentence names the CLI, the value and the set', () {
      expect(
        rejectedValueNotice('Codex', _codexRules.matchedBy(_refusedUntrusted)!),
        startsWith(
          "This Codex does not have 'untrusted' for '--ask-for-approval'; "
          'it has on-request, never.',
        ),
      );
    });
  });

  group('the sentence reaches the session it was about', () {
    test('a pane that died on its command line posts a notice and logs one '
        'line', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final records = _captureLogs();

      // Exactly what `AppShell` does: watched, not read, or Riverpod pauses the
      // subscription and no pane ever stops.
      h.container.listen(sessionLivenessReconcilerProvider, (_, _) {});

      final session = await _launch(h.container, h.db);
      _writeToPane(
        h.container,
        session.pane,
        '${[for (final line in _refusedUntrusted) _wrapped(line, 24)].join()}'
        '[process exited with code 2]\r\n',
      );
      _killProcess(h.container, session.pane);

      final notice = h.container.read(sessionNoticeProvider(session.id));
      expect(notice, isNotNull);
      expect(notice!.tone, SessionNoticeTone.warning);
      expect(
        notice.message,
        "This Codex does not have 'untrusted' for '--ask-for-approval'; "
        'it has on-request, never. It refused the command line and exited '
        'before starting.',
      );

      final lines = records
          .where((r) => r.loggerName == 'sessions.launch')
          .map((r) => r.message)
          .where((m) => m.startsWith('Refused ${session.id}'))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains("value='untrusted'"));
      expect(lines.single, contains('offered=on-request, never'));
      expect(lines.single, contains('pane=${session.pane}'));
    });

    test('an ordinary exit says nothing', () async {
      final h = await harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      h.container.listen(sessionLivenessReconcilerProvider, (_, _) {});

      final session = await _launch(h.container, h.db);
      _writeToPane(h.container, session.pane, 'Done. Bye!\r\n');
      _killProcess(h.container, session.pane);

      expect(h.container.read(sessionNoticeProvider(session.id)), isNull);
    });
  });
}
