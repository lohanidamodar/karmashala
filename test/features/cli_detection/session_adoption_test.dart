import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/cli_detection/application/session_adoption_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/cli_detection/domain/detected_session.dart';
import 'package:karmashala/src/features/cli_detection/domain/imported_session.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Adopting a session the user started by hand in one of our panes.
///
/// The load-bearing property is **idempotence**: however many signals arrive
/// about one conversation — a hook, a screen, a store sweep, a restart — there
/// is exactly one row for it, keyed by the id the CLI itself uses.

const _repoPath = r'C:\src\demo\app';

class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

typedef Harness = ({
  AppDatabase db,
  SessionAdoptionService service,
  SessionDao sessions,
  ImportedSessionDao imported,
  List<AdoptablePane> panes,
  List<DetectedSession> store,
  Map<String, List<String>> screens,
  _MovableClock clock,
  List<Session> adopted,
  _Counters counters,
});

class _Counters {
  int scans = 0;
  int paneReads = 0;
  int tailReads = 0;
}

AdoptablePane pane(
  String id, {
  String? directory = _repoPath,
  bool live = true,
  bool launched = false,
  String? commandId,
  String? commandLine,
  bool running = true,
}) => AdoptablePane(
  paneId: id,
  workingDirectory: directory,
  isLive: live,
  hostsLaunchedSession: launched,
  lastCommandId: commandId,
  lastCommandLine: commandLine,
  lastCommandRunning: running,
);

DetectedSession detected(
  String sessionId, {
  String cli = AgentIds.claudeCode,
  String path = _repoPath,
  DateTime? modifiedAt,
  String title = 'Fix the parser',
}) => DetectedSession(
  cli: cli,
  sessionId: sessionId,
  cwd: EnvironmentPath(environmentId: 'windows', path: path),
  filePath: 'C:\\store\\$sessionId.jsonl',
  storeHome: r'C:\store',
  title: title,
  modifiedAt: modifiedAt,
);

Harness harness({AppDatabase? database, bool installAgents = true}) {
  final db = database ?? AppDatabase.memory();
  if (database == null) {
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    if (installAgents) {
      AgentInstallationDao(db)
        ..insert(agentInstallation(agentId: AgentIds.claudeCode))
        ..insert(
          agentInstallation(
            id: 'a2',
            agentId: AgentIds.codex,
            path: r'C:\Users\me\.bin\codex.exe',
          ),
        )
        ..insert(
          agentInstallation(
            id: 'a3',
            agentId: AgentIds.antigravity,
            path: r'C:\Users\me\.bin\agy.cmd',
          ),
        );
    }
  }
  final panes = <AdoptablePane>[];
  final store = <DetectedSession>[];
  final screens = <String, List<String>>{};
  final adopted = <Session>[];
  final counters = _Counters();
  final clock = _MovableClock(testTime);
  final service = SessionAdoptionService(
    sessionDao: SessionDao(db),
    importedSessionDao: ImportedSessionDao(db),
    repositoryDao: RepositoryDao(db),
    environmentDao: ExecutionEnvironmentDao(db),
    installationDao: AgentInstallationDao(db),
    linkDao: SessionRepositoryDao(db),
    agents: AgentRegistry.builtIn,
    ids: SequentialIdGenerator('adopted-'),
    clock: clock,
    readPanes: () {
      counters.paneReads++;
      return List.of(panes);
    },
    readPaneTail: (paneId, lines) {
      counters.tailReads++;
      return screens[paneId] ?? const [];
    },
    scanStores: () async {
      counters.scans++;
      return List.of(store);
    },
    onAdopted: adopted.add,
  );
  return (
    db: db,
    service: service,
    sessions: SessionDao(db),
    imported: ImportedSessionDao(db),
    panes: panes,
    store: store,
    screens: screens,
    clock: clock,
    adopted: adopted,
    counters: counters,
  );
}

/// The two observations a real pane produces for one typed command: the prompt
/// (block id, no text yet) and the command actually running.
void typeCommand(
  Harness h,
  String paneId,
  String block,
  String line, {
  String directory = _repoPath,
}) {
  h.panes
    ..clear()
    ..add(pane(paneId, directory: directory, commandId: block));
  h.service.observePanes();
  h.panes
    ..clear()
    ..add(
      pane(paneId, directory: directory, commandId: block, commandLine: line),
    );
  h.service.observePanes();
}

void main() {
  group('a pane that starts an agent', () {
    test('is adopted once, and a second signal adds no second row', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');

      h.service.onHook(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-abc',
        cwd: _repoPath,
      );
      // Everything a busy agent fires afterwards.
      for (var i = 0; i < 20; i++) {
        h.service.onHook(
          agentId: AgentIds.claudeCode,
          sessionId: 'cli-abc',
          cwd: _repoPath,
        );
      }

      final rows = h.sessions.getAll();
      expect(rows, hasLength(1));
      expect(h.service.adoptions, 1);
      final row = rows.single;
      expect(row.externalSessionId, 'cli-abc');
      expect(row.paneId, 'pane-1');
      expect(row.repositoryId, 'r1');
      expect(row.surface, SessionSurface.pane);
      expect(row.status, SessionStatus.running);
      expect(h.adopted.single.id, row.id);
    });

    test('a store sweep after a hook adopts nothing new', () async {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');
      h.store.add(detected('cli-abc', modifiedAt: testTime));

      await h.service.sweep();

      expect(h.sessions.getAll(), hasLength(1));
      expect(h.service.adoptions, 1);
    });

    test('a hook after a store sweep adopts nothing new', () async {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.store.add(detected('cli-abc', modifiedAt: testTime));

      await h.service.sweep();
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.sessions.getAll(), hasLength(1));
      expect(h.sessions.getAll().single.externalSessionId, 'cli-abc');
      expect(h.service.adoptions, 1);
    });

    test('the store sweep names the conversation for an agent with no hooks',
        () async {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'codex');
      h.store.add(
        detected(
          'codex-1',
          cli: AgentIds.codex,
          modifiedAt: testTime,
          title: 'Port the reader',
        ),
      );

      expect(await h.service.sweep(), 1);

      final row = h.sessions.getAll().single;
      expect(row.externalSessionId, 'codex-1');
      expect(row.title, 'Port the reader');
      expect(row.agentInstallationId, 'a2');
    });

    test('two panes running one agent become two sessions, not one', () {
      final h = harness();
      h.panes
        ..add(pane('pane-1', commandId: 'a-0'))
        ..add(pane('pane-2', commandId: 'b-0'));
      h.service.observePanes();
      h.panes
        ..clear()
        ..add(pane('pane-1', commandId: 'a-0', commandLine: 'claude'))
        ..add(pane('pane-2', commandId: 'b-0', commandLine: 'claude'));
      h.service.observePanes();

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'first');
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'second');

      final rows = h.sessions.getAll();
      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.paneId).toSet(),
        {'pane-1', 'pane-2'},
        reason: 'a bound pane must stop being a candidate',
      );
    });
  });

  group('what is never adopted', () {
    test('a pane running a plain shell', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'ls -la');

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.service.armedPaneIds, isEmpty);
      expect(h.sessions.getAll(), isEmpty);
    });

    test('a hook from an agent running in somebody else\'s terminal', () {
      final h = harness();
      h.panes.add(pane('pane-1', commandId: 'cmd-0', commandLine: 'ls'));
      h.service.observePanes();

      h.service.onHook(
        agentId: AgentIds.claudeCode,
        sessionId: 'elsewhere',
        cwd: _repoPath,
      );

      expect(h.sessions.getAll(), isEmpty);
    });

    test('a pane the app itself launched an agent into', () {
      final h = harness();
      h.panes.add(
        pane('pane-1', launched: true, commandId: 'cmd-0', commandLine: 'claude'),
      );
      h.service.observePanes();

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.service.armedPaneIds, isEmpty);
      expect(h.sessions.getAll(), isEmpty);
    });

    test('a pane in a directory no repository owns', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.panes
        ..clear()
        ..add(
          pane(
            'pane-1',
            directory: r'C:\elsewhere',
            commandId: 'cmd-1',
            commandLine: 'claude',
          ),
        );
      h.service.observePanes();

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.sessions.getAll(), isEmpty);
    });

    test('an agent with no installation in the repository\'s environment', () {
      final db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      final h = harness(database: db);
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.sessions.getAll(), isEmpty);
    });

    test('a store session older than the pane, or in another directory',
        () async {
      final h = harness();
      h.clock.now = testTime.add(const Duration(minutes: 5));
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.store
        ..add(detected('stale', modifiedAt: testTime))
        ..add(
          detected(
            'other-folder',
            path: r'C:\src\demo\other',
            modifiedAt: h.clock.now,
          ),
        );

      expect(await h.service.sweep(), 0);
      expect(h.sessions.getAll(), isEmpty);
    });

    test('an agent that has exited leaves its pane free again', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      expect(h.service.armedPaneIds, ['pane-1']);

      // Claude exits; the shell draws a fresh prompt, which is a new block.
      h.panes
        ..clear()
        ..add(pane('pane-1', commandId: 'cmd-1'));
      h.service.observePanes();

      expect(h.service.armedPaneIds, isEmpty);
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');
      expect(h.sessions.getAll(), isEmpty);
    });

    test('a command that has finished disarms its pane before the next prompt',
        () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude --help');
      expect(h.service.armedPaneIds, ['pane-1']);

      // `claude --help` printed its usage and exited. The shell reports that on
      // the block it has already shown us, which keeps its id and its text — so
      // this flag is the only thing separating a CLI that has exited from an
      // agent sitting at its prompt.
      h.panes
        ..clear()
        ..add(
          pane(
            'pane-1',
            commandId: 'cmd-0',
            commandLine: 'claude --help',
            running: false,
          ),
        );
      h.service.observePanes();

      expect(h.service.armedPaneIds, isEmpty);
      // A hook from a Claude Code running in somebody else's terminal must not
      // find a home in a pane that is back at a shell prompt.
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');
      expect(h.sessions.getAll(), isEmpty);
    });

    test('a command that has finished buys no store scan', () async {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude --help');
      h.panes
        ..clear()
        ..add(
          pane(
            'pane-1',
            commandId: 'cmd-0',
            commandLine: 'claude --help',
            running: false,
          ),
        );
      h.service.observePanes();

      expect(h.service.wantsStoreSweep, isFalse);
      expect(await h.service.sweep(), 0);
      expect(h.counters.scans, 0);
    });

    test('a pane that has gone away', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.panes.clear();
      h.service.observePanes();

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.sessions.getAll(), isEmpty);
    });
  });

  group('one conversation, one row', () {
    test('an imported record is replaced by the live row, not doubled', () {
      final h = harness();
      h.imported.insertIfAbsent(
        ImportedSession(
          id: 'imp-1',
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: 'cli-abc',
          environmentId: 'windows',
          filePath: r'C:\store\cli-abc.jsonl',
          storeHome: r'C:\store',
          isSubagent: false,
          preview: 'earlier work',
          createdAt: testTime,
        ),
      );
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.sessions.getAll(), hasLength(1));
      expect(h.imported.getAll(), isEmpty);
    });

    test('a restart re-reads the row instead of minting a second', () {
      final first = harness();
      typeCommand(first, 'pane-1', 'cmd-0', 'claude');
      first.service.onHook(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-abc',
      );
      final adoptedId = first.sessions.getAll().single.id;

      // A new process: the same database, none of the in-memory signals.
      final second = harness(database: first.db);
      typeCommand(second, 'pane-9', 'cmd-0', 'claude');
      second.service.onHook(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-abc',
      );

      final rows = second.sessions.getAll();
      expect(rows, hasLength(1));
      expect(rows.single.id, adoptedId);
      expect(second.service.adoptions, 0);
    });

    test('a row with no pane is rejoined and goes back to running', () {
      final h = harness();
      SessionDao(h.db).insert(
        session(id: 'old', status: SessionStatus.completed).copyWith(
          externalSessionId: 'cli-abc',
        ),
      );
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      final rows = h.sessions.getAll();
      expect(rows, hasLength(1));
      expect(rows.single.paneId, 'pane-1');
      expect(rows.single.status, SessionStatus.running);
    });

    test('a row already naming a pane is left where it is', () {
      final h = harness();
      SessionDao(h.db).insert(
        session(id: 'live', status: SessionStatus.running).copyWith(
          externalSessionId: 'cli-abc',
          paneId: 'pane-elsewhere',
        ),
      );
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');

      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(h.sessions.getAll().single.paneId, 'pane-elsewhere');
    });
  });

  group('a screen can arm a pane its shell cannot', () {
    test('an unmistakable agent screen arms a pane with no OSC 133', () async {
      final h = harness();
      h.panes.add(pane('pane-1'));
      h.screens['pane-1'] = ['', '  ? for shortcuts · shift+tab to cycle  '];
      h.store.add(detected('cli-abc', modifiedAt: testTime));

      expect(await h.service.sweep(), 1);
      expect(h.sessions.getAll().single.externalSessionId, 'cli-abc');
    });

    test('a screen two agents could have drawn arms nothing', () async {
      final h = harness();
      h.panes.add(pane('pane-1'));
      // Claude Code and Codex both say this while they work.
      h.screens['pane-1'] = ['  working… (esc to interrupt)'];
      h.store.add(detected('cli-abc', modifiedAt: testTime));

      expect(await h.service.sweep(), 0);
      expect(h.service.armedPaneIds, isEmpty);
    });

    test('a plain shell screen arms nothing', () async {
      final h = harness();
      h.panes.add(pane('pane-1'));
      h.screens['pane-1'] = [r'PS C:\src\demo\app> '];

      expect(await h.service.sweep(), 0);
      expect(h.service.armedPaneIds, isEmpty);
    });
  });

  group('what it costs', () {
    test('watching panes never touches the disk', () {
      final h = harness();
      h.panes.add(pane('pane-1', commandId: 'cmd-0'));

      // A thousand cycles' worth of a user typing at a prompt.
      for (var i = 0; i < 1000; i++) {
        h.service.observePanes();
      }

      expect(h.counters.scans, 0);
      expect(h.counters.tailReads, 0);
      expect(h.service.storeSweeps, 0);
      expect(h.counters.paneReads, 1000);
    });

    test('an idle workspace buys no store scan even on the store slot',
        () async {
      final h = harness();
      h.panes.add(pane('pane-1', commandId: 'cmd-0', commandLine: 'ls'));
      h.service.observePanes();

      for (var i = 0; i < 50; i++) {
        expect(await h.service.sweep(), 0);
      }

      expect(h.counters.scans, 0);
      expect(h.service.storeSweeps, 0);
    });

    test('one scan answers for a hundred armed panes', () async {
      final h = harness();
      for (var i = 0; i < 100; i++) {
        h.panes.add(pane('pane-$i', commandId: 'c-$i', commandLine: 'claude'));
      }
      h.service.observePanes();
      h.store.add(detected('cli-abc', modifiedAt: testTime));

      await h.service.sweep();

      expect(h.counters.scans, 1);
      expect(h.service.storeSweeps, 1);
      // The one store session goes to exactly one of them.
      expect(h.sessions.getAll(), hasLength(1));
    });

    test('an unresolvable pane stops asking for scans', () async {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');

      for (var i = 0; i < 50; i++) {
        await h.service.sweep();
      }

      expect(h.counters.scans, kAdoptionSweepAttempts);
      expect(h.service.wantsStoreSweep, isFalse);
    });
  });

  group('a pane that moves on to something else', () {
    test('the row it adopted stops naming the pane', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');
      final adopted = h.sessions.getAllByExternalSessionId('cli-abc').single;
      expect(adopted.paneId, 'pane-1');

      // The user quits Claude. The pane survives, because it is a shell — so
      // without this the row goes on claiming a pane that is showing a prompt,
      // and the status badge reads that prompt as the agent's screen.
      h.panes
        ..clear()
        ..add(
          pane(
            'pane-1',
            commandId: 'cmd-0',
            commandLine: 'claude',
            running: false,
          ),
        );
      h.service.observePanes();

      expect(h.sessions.getById(adopted.id)!.paneId, isNull);
    });

    test('a second agent in one pane is a second row, not a changed one', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');
      final first = h.sessions.getAllByExternalSessionId('cli-abc').single;

      typeCommand(h, 'pane-1', 'cmd-1', 'claude');
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-def');
      final second = h.sessions.getAllByExternalSessionId('cli-def').single;

      expect(second.id, isNot(first.id));
      expect(second.paneId, 'pane-1');
      // The first conversation keeps everything that made it itself, and loses
      // only the pane the second one now owns.
      final after = h.sessions.getById(first.id)!;
      expect(after.paneId, isNull);
      expect(after.title, first.title);
      expect(after.createdAt, first.createdAt);
      expect(after.externalSessionId, 'cli-abc');
    });

    test('an empty prompt line does not resurrect the command before it', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');
      h.panes
        ..clear()
        ..add(
          pane(
            'pane-1',
            commandId: 'cmd-0',
            commandLine: 'claude',
            running: false,
          ),
        );
      h.service.observePanes();

      // The user presses Enter on an empty line. `CommandBlockTracker` opens a
      // block for the prompt and then drops it, because nothing ran — so
      // `latest` falls back to the *previous, completed* block, and the pane
      // reports `claude` all over again.
      h.panes
        ..clear()
        ..add(pane('pane-1', commandId: 'cmd-1'));
      h.service.observePanes();
      h.panes
        ..clear()
        ..add(
          pane(
            'pane-1',
            commandId: 'cmd-0',
            commandLine: 'claude',
            running: false,
          ),
        );
      h.service.observePanes();

      // Nothing is running there, so nothing is armed and no second row is
      // minted for an agent that exited a moment ago.
      expect(h.service.armedPaneIds, isEmpty);
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-def');
      expect(h.sessions.getAll(), hasLength(1));
    });

    test('a row a resume has since moved is left where it is', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude');
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');
      final adopted = h.sessions.getAllByExternalSessionId('cli-abc').single;
      // A resume re-launched the conversation into a pane of its own. That
      // placement is newer than ours, so leaving this pane must not undo it.
      h.sessions.updatePaneId(adopted.id, 'pane-9');

      h.panes
        ..clear()
        ..add(
          pane(
            'pane-1',
            commandId: 'cmd-0',
            commandLine: 'claude',
            running: false,
          ),
        );
      h.service.observePanes();

      expect(h.sessions.getById(adopted.id)!.paneId, 'pane-9');
    });
  });

  group('where the adopted session was actually running', () {
    const subdirectory = r'C:\src\demo\app\packages\ui';

    test('an agent started in a subdirectory records that subdirectory', () {
      // The whole point of the column. Claude Code and Codex key their
      // conversation stores by working directory, so a resume from the
      // repository root may not find this conversation at all.
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude', directory: subdirectory);
      h.service.onHook(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-abc',
        cwd: subdirectory,
      );

      final row = h.sessions.getAll().single;
      expect(row.workingDirectory?.path, subdirectory);
      // Bound to the environment of the repository the pane was matched
      // against — the same environment the match itself was made under, so the
      // path means what it meant when it was compared.
      expect(row.workingDirectory?.environmentId, 'windows');
    });

    test('the directory is never mistaken for a worktree', () {
      // `worktree` drives `use_worktree` and `WorktreeService.remove`, which
      // deletes the directory. A hand-started agent's cwd is the user's own
      // checkout; recording it there would offer to delete it.
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'claude', directory: subdirectory);
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      final row = h.sessions.getAll().single;
      expect(row.worktree, isNull);
      expect(row.useWorktree, isFalse);
    });

    test('a store-swept adoption records the pane it was swept for', () async {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'codex', directory: subdirectory);
      h.store.add(
        detected(
          'codex-1',
          cli: AgentIds.codex,
          path: subdirectory,
          modifiedAt: testTime,
        ),
      );

      expect(await h.service.sweep(), 1);
      expect(h.sessions.getAll().single.workingDirectory?.path, subdirectory);
    });

    test('rejoining a row that recorded no directory records this one', () {
      // A row from before schema v22, or one whose agent was quit and started
      // again in a different folder. It has no directory and the pane knows
      // one, so recording it replaces nothing.
      final h = harness();
      h.sessions.insert(
        session(id: 's-old', title: 'Earlier').copyWith(
          externalSessionId: 'cli-abc',
        ),
      );

      typeCommand(h, 'pane-1', 'cmd-0', 'claude', directory: subdirectory);
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      final row = h.sessions.getById('s-old')!;
      expect(row.paneId, 'pane-1');
      expect(row.workingDirectory?.path, subdirectory);
    });

    test('rejoining never overwrites a directory the row already has', () {
      final h = harness();
      h.sessions.insert(
        session(
          id: 's-old',
          title: 'Earlier',
          workingDirectory: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\src\demo\app\tool',
          ),
        ).copyWith(externalSessionId: 'cli-abc'),
      );

      typeCommand(h, 'pane-1', 'cmd-0', 'claude', directory: subdirectory);
      h.service.onHook(agentId: AgentIds.claudeCode, sessionId: 'cli-abc');

      expect(
        h.sessions.getById('s-old')!.workingDirectory?.path,
        r'C:\src\demo\app\tool',
      );
    });

    test('adopts Antigravity session from hook payload with workspacePaths list', () {
      final h = harness();
      typeCommand(h, 'pane-1', 'cmd-0', 'agy', directory: _repoPath);
      h.service.onHookPayload(
        agentId: AgentIds.antigravity,
        sessionId: 'agy-session-1',
        body: '{"conversationId":"agy-session-1","workspacePaths":["$_repoPath"]}',
      );

      final row = h.sessions.getAll().single;
      expect(row.externalSessionId, 'agy-session-1');
      expect(row.paneId, 'pane-1');
      expect(row.workingDirectory?.path, _repoPath);
    });
  });
}
