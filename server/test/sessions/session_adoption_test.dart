import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_host/protocol.dart' show PaneFacts;
import 'package:karmashala_host/src/sessions/session_adoption.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

import 'sync_fixture.dart';

/// Adopting a session a person started by hand in one of a client's panes —
/// at the server (slice 2b; moved from the app's `SessionAdoptionService`).
/// The client reports its panes as facts; the server arms, claims on hooks,
/// sweeps stores and writes rows.
///
/// The load-bearing property is **idempotence**: however many signals arrive
/// about one conversation — a hook, a screen, a store sweep, a restart — there
/// is exactly one row for it, keyed by the id the agent itself uses.
void main() {
  late SyncFixture world;
  late MovableClock clock;

  setUp(() {
    world = SyncFixture();
    clock = MovableClock(launchedAt);
  });
  tearDown(() => world.close());

  SessionAdoption adoption() =>
      SessionAdoption(rows: world.rows, newId: sequentialIds(), clock: clock);

  PaneFacts pane(
    String id, {
    String? directory = repoPath,
    bool live = true,
    bool launched = false,
    String? commandId,
    String? commandLine,
    bool running = true,
  }) => PaneFacts(
    paneId: id,
    workingDirectory: directory,
    live: live,
    hostsLaunchedSession: launched,
    lastCommandId: commandId,
    lastCommandLine: commandLine,
    lastCommandRunning: running,
  );

  DetectedSession found(
    String id, {
    String cli = AgentIds.claudeCode,
    String path = repoPath,
    DateTime? modifiedAt,
    String title = 'Fix the parser',
  }) => storeSession(
    id,
    cli: cli,
    cwd: path,
    title: title,
    modifiedAt: modifiedAt ?? launchedAt,
  );

  /// The two reports a real pane produces for one typed command: the prompt
  /// (block id, no text yet) and the command running.
  void typeCommand(
    SessionAdoption subject,
    String paneId,
    String block,
    String line, {
    String directory = repoPath,
  }) {
    subject.observePanes([
      pane(paneId, directory: directory, commandId: block),
    ]);
    subject.observePanes([
      pane(paneId, directory: directory, commandId: block, commandLine: line),
    ]);
  }

  void claudeHook(SessionAdoption subject, String id, {String cwd = ''}) =>
      subject.hook(agentId: AgentIds.claudeCode, conversationId: id, cwd: cwd);

  List<Session> rows() => world.sessions.getAll();

  group('a pane that starts an agent', () {
    test('is adopted once, and a second signal adds no second row', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');

      for (var i = 0; i < 21; i++) {
        claudeHook(subject, 'cli-abc', cwd: repoPath);
      }

      expect(rows(), hasLength(1));
      expect(subject.adoptions, 1);
      final row = rows().single;
      expect(row.externalSessionId, 'cli-abc');
      expect(row.paneId, 'pane-1');
      expect(row.repositoryId, 'r1');
      expect(row.agentInstallationId, 'a1');
      expect(row.surface, SessionSurface.pane);
      expect(row.status, SessionStatus.running);
      // Written through the data service: every client is told, with its
      // primary checkout.
      expect(world.toldRows, [row.id]);
      expect(
        world.db.query('SELECT * FROM session_repositories;'),
        hasLength(1),
      );
    });

    test('a store sweep after a hook adopts nothing new', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      expect(subject.sweep([found('cli-abc')]), 0);
      expect(rows(), hasLength(1));
      expect(subject.wantsStoreSweep, isFalse);
    });

    test('a hook after a store sweep adopts nothing new', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      expect(subject.sweep([found('cli-abc')]), 1);
      claudeHook(subject, 'cli-abc');
      expect(rows(), hasLength(1));
      expect(subject.adoptions, 1);
    });

    test(
      'the store sweep names the conversation for an agent with no hooks',
      () {
        final subject = adoption();
        typeCommand(subject, 'pane-1', 'cmd-0', 'codex');
        expect(
          subject.sweep([
            found('codex-1', cli: AgentIds.codex, title: 'Port the reader'),
          ]),
          1,
        );
        final row = rows().single;
        expect(row.externalSessionId, 'codex-1');
        expect(row.title, 'Port the reader');
        expect(row.agentInstallationId, 'a2');
      },
    );

    test('two panes running one agent become two sessions, not one', () {
      final subject = adoption();
      subject.observePanes([
        pane('pane-1', commandId: 'a-0'),
        pane('pane-2', commandId: 'b-0'),
      ]);
      subject.observePanes([
        pane('pane-1', commandId: 'a-0', commandLine: 'claude'),
        pane('pane-2', commandId: 'b-0', commandLine: 'claude'),
      ]);
      claudeHook(subject, 'first');
      claudeHook(subject, 'second');
      expect(rows().map((r) => r.paneId).toSet(), {'pane-1', 'pane-2'});
    });

    test('a hook names its pane by directory before age', () {
      const other = r'C:\src\demo\app\tool';
      final subject = adoption();
      subject.observePanes([
        pane('pane-1', commandId: 'a-0'),
        pane('pane-2', directory: other, commandId: 'b-0'),
      ]);
      subject.observePanes([
        pane('pane-1', commandId: 'a-0', commandLine: 'claude'),
        pane(
          'pane-2',
          directory: other,
          commandId: 'b-0',
          commandLine: 'claude',
        ),
      ]);
      claudeHook(subject, 'cli-abc', cwd: other.toUpperCase());
      expect(rows().single.paneId, 'pane-2');
    });
  });

  group('what is never adopted', () {
    test('a pane running a plain shell', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'ls -la');
      claudeHook(subject, 'cli-abc');
      expect(subject.armedPaneIds, isEmpty);
      expect(rows(), isEmpty);
    });

    test('a pane the client itself launched an agent into', () {
      final subject = adoption();
      subject.observePanes([
        pane('pane-1', launched: true, commandId: 'c', commandLine: 'claude'),
      ]);
      claudeHook(subject, 'cli-abc');
      expect(subject.armedPaneIds, isEmpty);
      expect(rows(), isEmpty);
    });

    test('a pane in a directory no checkout owns', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude', directory: r'C:\else');
      claudeHook(subject, 'cli-abc');
      expect(rows(), isEmpty);
      expect(world.told, isEmpty);
    });

    test('an agent with no installation in the checkout\'s environment', () {
      world.db.execute("DELETE FROM agent_installations WHERE id = 'a1';");
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      expect(rows(), isEmpty);
    });

    test('a store conversation older than the pane, or elsewhere', () {
      clock.now = launchedAt.add(const Duration(minutes: 5));
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      expect(
        subject.sweep([
          found('stale', modifiedAt: launchedAt),
          found('other', path: r'C:\src\demo\other', modifiedAt: clock.now),
        ]),
        0,
      );
      expect(rows(), isEmpty);
    });

    test('an agent that has exited leaves its pane free again', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      expect(subject.armedPaneIds, ['pane-1']);
      subject.observePanes([pane('pane-1', commandId: 'cmd-1')]);
      expect(subject.armedPaneIds, isEmpty);
      claudeHook(subject, 'cli-abc');
      expect(rows(), isEmpty);
    });

    test('a finished command disarms its pane before the next prompt', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude --help');
      subject.observePanes([
        pane(
          'pane-1',
          commandId: 'cmd-0',
          commandLine: 'claude --help',
          running: false,
        ),
      ]);
      expect(subject.armedPaneIds, isEmpty);
      expect(subject.wantsStoreSweep, isFalse);
      claudeHook(subject, 'cli-abc');
      expect(rows(), isEmpty);
    });

    test('a pane that has gone away, or whose client has', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      subject.observePanes(const []);
      claudeHook(subject, 'cli-abc');
      expect(rows(), isEmpty);
    });
  });

  group('one conversation, one row', () {
    test('imported history for it does not stop the live row', () {
      ImportedSessionDao(world.db).insertIfAbsent(
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
          createdAt: launchedAt,
        ),
      );
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      expect(rows(), hasLength(1));
    });

    test('a restart re-reads the row instead of minting a second', () {
      final first = adoption();
      typeCommand(first, 'pane-1', 'cmd-0', 'claude');
      claudeHook(first, 'cli-abc');
      final adoptedId = rows().single.id;

      final second = adoption();
      typeCommand(second, 'pane-9', 'cmd-0', 'claude');
      claudeHook(second, 'cli-abc');
      expect(rows().single.id, adoptedId);
      expect(second.adoptions, 0);
    });

    test('a row with no pane is rejoined and goes back to running', () {
      world.insert(
        sessionRow(
          id: 'old',
          externalId: 'cli-abc',
          status: SessionStatus.completed,
        ),
      );
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      final row = rows().single;
      expect(row.paneId, 'pane-1');
      expect(row.status, SessionStatus.running);
      expect(world.toldRows, ['old']);
    });

    test('a row already naming a pane is left where it is', () {
      world.insert(
        sessionRow(id: 'live', externalId: 'cli-abc', paneId: 'pane-else'),
      );
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      expect(rows().single.paneId, 'pane-else');
      expect(world.told, isEmpty);
    });
  });

  group('a screen can arm a pane its shell cannot', () {
    test('an unmistakable agent screen arms a pane with no OSC 133', () {
      final subject = adoption();
      subject.observePanes([pane('pane-1')]);
      expect(subject.screenCandidates, ['pane-1']);
      subject.armFromScreens({
        'pane-1': ['', '  ? for shortcuts · shift+tab to cycle  '],
      });
      expect(subject.sweep([found('cli-abc')]), 1);
      expect(rows().single.externalSessionId, 'cli-abc');
      expect(subject.screenCandidates, isEmpty);
    });

    test('a screen two agents could have drawn arms nothing', () {
      final subject = adoption();
      subject.observePanes([pane('pane-1')]);
      subject.armFromScreens({
        'pane-1': ['  working… (esc to interrupt)'],
      });
      expect(subject.armedPaneIds, isEmpty);
    });

    test('a plain shell screen arms nothing', () {
      final subject = adoption();
      subject.observePanes([pane('pane-1')]);
      subject.armFromScreens({
        'pane-1': [r'PS C:\src\demo\app> '],
      });
      expect(subject.armedPaneIds, isEmpty);
    });

    test('no screen is read for a pane nobody sent', () {
      final subject = adoption();
      subject.observePanes([pane('pane-1'), pane('pane-2', live: false)]);
      expect(subject.screenCandidates, ['pane-1']);
      subject.armFromScreens(const {});
      expect(subject.gridReads, 0);
    });
  });

  group('what it costs', () {
    test('an idle workspace wants no store scan', () {
      final subject = adoption();
      subject.observePanes([pane('pane-1', commandId: 'c', commandLine: 'ls')]);
      for (var i = 0; i < 1000; i++) {
        subject.observePanes([
          pane('pane-1', commandId: 'c', commandLine: 'ls'),
        ]);
      }
      expect(subject.wantsStoreSweep, isFalse);
    });

    test('one scan answers for a hundred armed panes', () {
      final subject = adoption();
      subject.observePanes([
        for (var i = 0; i < 100; i++)
          pane('pane-$i', commandId: 'c-$i', commandLine: 'claude'),
      ]);
      subject.sweep([found('cli-abc')]);
      expect(rows(), hasLength(1));
    });

    test('an unresolvable pane stops asking for scans', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      var sweeps = 0;
      for (var i = 0; i < 50; i++) {
        if (!subject.wantsStoreSweep) break;
        sweeps++;
        subject.sweep(const []);
      }
      expect(sweeps, kAdoptionSweepAttempts);
    });
  });

  group('a pane that moves on to something else', () {
    test('the row it adopted stops naming the pane', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      final adopted = rows().single;
      subject.observePanes([
        pane(
          'pane-1',
          commandId: 'cmd-0',
          commandLine: 'claude',
          running: false,
        ),
      ]);
      expect(world.row(adopted.id)!.paneId, isNull);
      expect(world.toldRows, [adopted.id, adopted.id]);
    });

    test('a second agent in one pane is a second row, not a changed one', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      final first = world.sessions.getAllByExternalSessionId('cli-abc').single;
      typeCommand(subject, 'pane-1', 'cmd-1', 'claude');
      claudeHook(subject, 'cli-def');
      final second = world.sessions.getAllByExternalSessionId('cli-def').single;

      expect(second.id, isNot(first.id));
      expect(second.paneId, 'pane-1');
      final after = world.row(first.id)!;
      expect(after.paneId, isNull);
      expect(after.title, first.title);
      expect(after.externalSessionId, 'cli-abc');
    });

    test('an empty prompt line does not resurrect the command before it', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      final done = pane(
        'pane-1',
        commandId: 'cmd-0',
        commandLine: 'claude',
        running: false,
      );
      subject.observePanes([done]);
      subject.observePanes([pane('pane-1', commandId: 'cmd-1')]);
      subject.observePanes([done]);
      expect(subject.armedPaneIds, isEmpty);
      claudeHook(subject, 'cli-def');
      expect(rows(), hasLength(1));
    });

    test('a row a resume has since moved is left where it is', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'claude');
      claudeHook(subject, 'cli-abc');
      final adopted = rows().single;
      world.sessions.updatePaneId(adopted.id, 'pane-9');
      subject.observePanes([
        pane(
          'pane-1',
          commandId: 'cmd-0',
          commandLine: 'claude',
          running: false,
        ),
      ]);
      expect(world.row(adopted.id)!.paneId, 'pane-9');
    });
  });

  group('where the adopted session was actually running', () {
    const subdirectory = r'C:\src\demo\app\packages\ui';

    test('an agent started in a subdirectory records that subdirectory', () {
      final subject = adoption();
      typeCommand(
        subject,
        'pane-1',
        'cmd-0',
        'claude',
        directory: subdirectory,
      );
      claudeHook(subject, 'cli-abc', cwd: subdirectory);
      final row = rows().single;
      expect(row.workingDirectory?.path, subdirectory);
      expect(row.workingDirectory?.environmentId, 'windows');
      expect(row.worktree, isNull);
      expect(row.useWorktree, isFalse);
    });

    test('a store-swept adoption records the pane it was swept for', () {
      final subject = adoption();
      typeCommand(subject, 'pane-1', 'cmd-0', 'codex', directory: subdirectory);
      expect(
        subject.sweep([
          found('codex-1', cli: AgentIds.codex, path: subdirectory),
        ]),
        1,
      );
      expect(rows().single.workingDirectory?.path, subdirectory);
    });

    test('rejoining a row that recorded no directory records this one', () {
      world.insert(
        sessionRow(id: 's-old', externalId: 'cli-abc', directory: null),
      );
      final subject = adoption();
      typeCommand(
        subject,
        'pane-1',
        'cmd-0',
        'claude',
        directory: subdirectory,
      );
      claudeHook(subject, 'cli-abc');
      final row = world.row('s-old')!;
      expect(row.paneId, 'pane-1');
      expect(row.workingDirectory?.path, subdirectory);
    });

    test('rejoining never overwrites a directory the row already has', () {
      world.insert(
        sessionRow(
          id: 's-old',
          externalId: 'cli-abc',
          directory: r'C:\src\demo\app\tool',
        ),
      );
      final subject = adoption();
      typeCommand(
        subject,
        'pane-1',
        'cmd-0',
        'claude',
        directory: subdirectory,
      );
      claudeHook(subject, 'cli-abc');
      expect(
        world.row('s-old')!.workingDirectory?.path,
        r'C:\src\demo\app\tool',
      );
    });
  });
}
