import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/unresumable_sessions.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/temp_directory.dart';
import 'package:agent_cli/read.dart';

/// **The review, end to end: what it offers, what it refuses to offer, and
/// what the two verbs do to a row.**
///
/// The companion to `session_phantom_resume_test.dart`, which pins the
/// *reactive* half — a resume of a conversation the CLI never wrote is refused
/// with an explanation. This pins the half that goes looking, and above all the
/// cases where looking must come back empty-handed: a session we can see
/// running, a session started a moment ago, and a store nobody could read.
/// Each of those, offered for deletion, is data loss.

const _claudeish = AgentDescriptor(
  id: 'claudeish',
  displayName: 'Claudeish',
  binaries: AgentBinaries(windows: ['claudeish'], posix: ['claudeish']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--resume'),
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    allowsConcurrentResume: true,
  ),
  store: AgentStoreSpec(homeDirectoryName: '.claude'),
);

/// Codex's shape: it mints its own id, so it can never make the promise this
/// feature is about.
const _codexish = AgentDescriptor(
  id: 'codexish',
  displayName: 'Codexish',
  binaries: AgentBinaries(windows: ['codexish'], posix: ['codexish']),
  launch: AgentLaunchSpec(permission: testPermissionSupport),
  store: AgentStoreSpec(homeDirectoryName: '.codex'),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

/// A clock a test can wind on, so a row can be older than the grace window
/// without the row having to be rewritten behind the controller's back.
class _MovableClock implements Clock {
  _MovableClock(this._now);

  DateTime _now;

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime nowUtc() => _now.toUtc();
}

/// Counts how many times the stores were located, which is once per sweep.
class _CountingLocator extends CliStoreLocator {
  _CountingLocator(this.stores)
    : super(runnerFor: ((_) => FakeCommandRunner()));

  final List<CliStore> stores;
  int calls = 0;

  @override
  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async {
    calls++;
    return stores;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_unres_'));
  tearDown(() => removeTempDirectory(tmp));

  String storeHome() => p.join(tmp.path, '.claude');

  /// A store that exists and has been read to the end. Without it every answer
  /// is "we cannot tell", and nothing is ever offered.
  void emptyStore() =>
      Directory(p.join(storeHome(), 'projects')).createSync(recursive: true);

  void writeConversation(String id) {
    File(p.join(storeHome(), 'projects', '-c-src-demo-app', '$id.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"type":"user","cwd":"C:\\\\src\\\\demo\\\\app"}\n');
  }

  // The server the last [seededDatabase] filled.
  late FakeDataServer server;

  AppDatabase seededDatabase({bool withCodex = false}) {
    final db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(agentId: 'claudeish'));
    if (withCodex) {
      server.installationRows.insert(agentInstallation(id: 'a2', agentId: 'codexish'));
    }
    return db;
  }

  late _MovableClock clock;
  late _CountingLocator locator;

  Future<ProviderContainer> containerOver(
    AppDatabase db, {
    bool locatable = true,
    List<AgentAdapter> agents = const [
      ClaudeCodeAdapter(descriptor: _claudeish),
    ],
  }) async {
    clock = _MovableClock(testTime);
    locator = _CountingLocator([
      if (locatable)
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {
            'claudeish': storeHome(),
            'codexish': p.join(tmp.path, '.codex'),
          },
        ),
    ]);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await server.override(),
        clockProvider.overrideWithValue(clock),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(AgentRegistry(agents)),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        cliStoreLocatorProvider.overrideWithValue(locator),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Starts a session the way the app does. The returned id is also the
  /// conversation id it promised the CLI.
  Future<String> startSession(
    ProviderContainer container, {
    String installationId = 'a1',
    String agentId = 'claudeish',
  }) async {
    final launched = await container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(
              id: installationId,
              agentId: agentId,
            ),
            title: 'New session',
            purpose: SessionPurpose.newSession,
          ),
        );
    return launched.session.id;
  }

  /// The state a failed launch leaves: the row and its promise, no pane, and
  /// old enough to judge.
  String seedDeadRow(
    ProviderContainer container, {
    String id = 'dead-1',
    String title = 'Dead session',
    String installationId = 'a1',
  }) {
    serverOf(container).sessionRows.insert(
      session(
        id: id,
        title: title,
        agentInstallationId: installationId,
      ).copyWith(
        externalSessionId: id,
        status: SessionStatus.running,
        createdAt: testTime.subtract(const Duration(hours: 2)),
      ),
    );
    return id;
  }

  group('what the review finds', () {
    test('a row whose conversation was never written is removable', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      final id = seedDeadRow(container);

      await container.read(unresumableSessionsProvider.notifier).refresh();
      final review = container.read(unresumableSessionsProvider);

      expect(review.removable.map((r) => r.session.id), [id]);
      expect(review.uncertain, isEmpty);
      expect(review.removable.single.verdict, PromiseVerdict.unkept);
      expect(review.removable.single.note, contains('Claudeish'));
      expect(review.summary, contains('1 session'));
      expect(review.checkedAt, testTime);
    });

    test('a row whose conversation is on disk is not offered', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      final id = seedDeadRow(container);
      writeConversation(id);

      await container.read(unresumableSessionsProvider.notifier).refresh();
      final review = container.read(unresumableSessionsProvider);

      expect(review.removable, isEmpty);
      expect(review.uncertain, isEmpty);
      expect(review.summary, contains('No session'));
    });

    test('a store nobody could locate leaves the row uncertain, never '
        'removable', () async {
      // The stopped WSL distribution, and the reason `unknown` exists.
      final db = seededDatabase();
      addTearDown(db.close);
      final container = await containerOver(db, locatable: false);
      final id = seedDeadRow(container);

      await container.read(unresumableSessionsProvider.notifier).refresh();
      final review = container.read(unresumableSessionsProvider);

      expect(review.removable, isEmpty);
      expect(review.uncertain.map((r) => r.session.id), [id]);
      expect(review.uncertain.single.verdict, PromiseVerdict.unknown);
      expect(review.storesRead, 0);
      expect(review.summary, contains('Nothing will be removed'));
    });

    test(
      'a store that is there but unreadable leaves the row uncertain',
      () async {
        // Located, asked, and it had no `projects` directory to read.
        final db = seededDatabase();
        addTearDown(db.close);
        Directory(storeHome()).createSync(recursive: true);
        final container = await containerOver(db);
        seedDeadRow(container);

        await container.read(unresumableSessionsProvider.notifier).refresh();
        final review = container.read(unresumableSessionsProvider);

        expect(review.removable, isEmpty);
        expect(review.uncertain, hasLength(1));
        expect(review.storesUnreadable, greaterThan(0));
      },
    );

    test('a session started a moment ago is not offered', () async {
      // The row and the store look exactly like a dead one — the transcript is
      // written when something is *said*. Only its age says otherwise.
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      await startSession(container);

      await container.read(unresumableSessionsProvider.notifier).refresh();
      final review = container.read(unresumableSessionsProvider);

      expect(review.removable, isEmpty);
      expect(review.uncertain, isEmpty);
    });

    test('a session we can see running is not offered however old', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      final id = await startSession(container);
      // Old enough that the grace window has nothing to say about it.
      clock.advance(const Duration(days: 3));
      expect(
        container.read(sessionLauncherProvider).livePaneFor(id),
        isNotNull,
        reason:
            'the pane must still be live for this to be the case under test',
      );

      await container.read(unresumableSessionsProvider.notifier).refresh();
      final review = container.read(unresumableSessionsProvider);

      expect(review.removable, isEmpty);
      expect(review.uncertain, isEmpty);
    });

    test('an agent that mints its own id is never judged', () async {
      final db = seededDatabase(withCodex: true);
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(
        db,
        agents: const [
          ClaudeCodeAdapter(descriptor: _claudeish),
          CodexAdapter(descriptor: _codexish),
        ],
      );
      // A Codex-shaped row: an external id the CLI chose, not one we promised.
      container
          .read(sessionsDataProvider)
          .insert(
            session(id: 'codex-row', agentInstallationId: 'a2').copyWith(
              externalSessionId: 'thread-99',
              status: SessionStatus.running,
              createdAt: testTime.subtract(const Duration(hours: 2)),
            ),
          );

      await container.read(unresumableSessionsProvider.notifier).refresh();
      final review = container.read(unresumableSessionsProvider);

      expect(review.removable, isEmpty);
      expect(review.uncertain, isEmpty);
    });

    test('no candidate means no store is read at all', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      await startSession(container);

      await container.read(unresumableSessionsProvider.notifier).refresh();

      expect(
        locator.calls,
        0,
        reason:
            'screening is free; the sweep is only paid for when it can '
            'answer something',
      );
      expect(container.read(unresumableSessionsProvider).hasRun, isTrue);
    });

    test('one refresh reads the stores once, whatever the row count', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      for (var i = 0; i < 25; i++) {
        seedDeadRow(container, id: 'dead-$i');
      }

      await container.read(unresumableSessionsProvider.notifier).refresh();

      expect(
        container.read(unresumableSessionsProvider).removable,
        hasLength(25),
      );
      expect(locator.calls, 1);
    });
  });

  group('removing', () {
    test('deletes the removable rows and leaves the uncertain ones', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      // Two rows, one store: readable so the first is `absent`, and a second
      // row in an environment the sweep never read so it stays `unknown`.
      server.environmentRows.upsert(wslEnv());
      emptyStore();
      final container = await containerOver(db);
      final dead = seedDeadRow(container, id: 'dead-1');
      container
          .read(sessionsDataProvider)
          .insert(
            session(id: 'elsewhere').copyWith(
              externalSessionId: 'elsewhere',
              status: SessionStatus.running,
              createdAt: testTime.subtract(const Duration(hours: 2)),
              workingDirectory: const EnvironmentPath(
                environmentId: 'wsl:Ubuntu',
                path: '/home/me/app',
              ),
            ),
          );

      final notifier = container.read(unresumableSessionsProvider.notifier);
      await notifier.refresh();
      expect(
        container.read(unresumableSessionsProvider).removable,
        hasLength(1),
      );
      expect(
        container.read(unresumableSessionsProvider).uncertain,
        hasLength(1),
      );

      // Both ids offered; only the judged one may go.
      notifier.remove(['dead-1', 'elsewhere']);

      final dao = container.read(sessionsDataProvider);
      expect(dao.getById(dead), isNull);
      expect(dao.getById('elsewhere'), isNotNull);
      expect(container.read(unresumableSessionsProvider).removable, isEmpty);
      expect(
        container.read(unresumableSessionsProvider).uncertain,
        hasLength(1),
      );
    });

    test(
      'an id the reading never judged cannot be removed through it',
      () async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        final container = await containerOver(db);
        final live = await startSession(container);
        seedDeadRow(container, id: 'dead-1');

        final notifier = container.read(unresumableSessionsProvider.notifier);
        await notifier.refresh();
        notifier.remove([live, 'dead-1']);

        final dao = container.read(sessionsDataProvider);
        expect(
          dao.getById(live),
          isNotNull,
          reason: 'the running session was never in the reading',
        );
        expect(dao.getById('dead-1'), isNull);
      },
    );

    test('removing nothing removes nothing', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      seedDeadRow(container, id: 'dead-1');
      final notifier = container.read(unresumableSessionsProvider.notifier);
      await notifier.refresh();

      notifier.remove(const []);

      expect(container.read(sessionsDataProvider).getById('dead-1'), isNotNull);
    });
  });

  group('starting a conversation in the row instead', () {
    test('keeps the row and re-makes the promise', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      final id = seedDeadRow(container, title: 'Refactor the parser');

      final notifier = container.read(unresumableSessionsProvider.notifier);
      await notifier.refresh();
      final started = await notifier.restart(id);

      // Everything a delete would have thrown away.
      expect(started.id, id);
      expect(started.title, 'Refactor the parser');
      expect(started.createdAt, testTime.subtract(const Duration(hours: 2)));
      expect(
        container.read(sessionsDataProvider).getAll().where((s) => s.id == id),
        hasLength(1),
      );
      // The promise, made again — and it is the same string, because the
      // conversation id a `--session-id` agent gets *is* the row id.
      final row = container.read(sessionsDataProvider).getById(id)!;
      expect(row.externalSessionId, id);
      expect(row.status, SessionStatus.running);
      expect(row.paneId, isNotNull);
      // Off the list, so the sheet does not offer to delete what was just
      // started.
      expect(container.read(unresumableSessionsProvider).removable, isEmpty);
    });

    test(
      'is a create, not a resume — the CLI is never told to resume',
      () async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        final container = await containerOver(db);
        final id = seedDeadRow(container);

        final notifier = container.read(unresumableSessionsProvider.notifier);
        await notifier.refresh();
        final started = await notifier.restart(id);

        final launch = container
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(started.paneId!)!
            .agentLaunch!;
        expect(
          launch.arguments,
          isNot(contains('--resume')),
          reason:
              'there is no conversation to resume — that is the whole state',
        );
        expect(launch.arguments, containsAllInOrder(['--session-id', id]));
      },
    );

    test('a launch that both restarts and resumes is refused', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);
      final id = seedDeadRow(container);

      await expectLater(
        container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: agentInstallation(agentId: 'claudeish'),
                title: 'Both',
                purpose: SessionPurpose.newSession,
                restartSessionId: id,
                resumeExternalSessionId: id,
              ),
            ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'refused on the shape of the request, before any store is read',
      () async {
        // The case the ordering matters for. With no readable store,
        // `conversationToResume` answers "we cannot tell" and returns
        // normally — so if the guard ran after it, this launch would proceed and
        // the reuse would silently prefer the resume, giving the user a resume of
        // a conversation they asked to replace.
        final db = seededDatabase();
        addTearDown(db.close);
        final container = await containerOver(db, locatable: false);
        final id = seedDeadRow(container);

        await expectLater(
          container
              .read(sessionLauncherProvider)
              .launch(
                SessionLaunchRequest(
                  repository: repository(),
                  installation: agentInstallation(agentId: 'claudeish'),
                  title: 'Both',
                  purpose: SessionPurpose.newSession,
                  restartSessionId: id,
                  resumeExternalSessionId: id,
                ),
              ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          locator.calls,
          0,
          reason:
              'nothing may be read to turn down a request that makes no '
              'sense',
        );
      },
    );

    test(
      'a restart naming a row a pane is running falls back to a new row',
      () async {
        // The guard against abandoning a live conversation: the row is busy, so
        // reuse is refused and the launch is an ordinary create.
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        final container = await containerOver(db);
        final live = await startSession(container);

        final launched = await container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: agentInstallation(agentId: 'claudeish'),
                title: 'Second',
                purpose: SessionPurpose.newSession,
                restartSessionId: live,
              ),
            );

        expect(launched.session.id, isNot(live));
        expect(container.read(sessionsDataProvider).getById(live), isNotNull);
      },
    );

    test('a row nothing could judge gets neither verb', () async {
      // The mirror of the removal guard, and it matters as much: an
      // unreachable store may still hold that conversation.
      final db = seededDatabase();
      addTearDown(db.close);
      final container = await containerOver(db, locatable: false);
      final id = seedDeadRow(container);

      final notifier = container.read(unresumableSessionsProvider.notifier);
      await notifier.refresh();
      expect(
        container.read(unresumableSessionsProvider).uncertain,
        hasLength(1),
      );

      await expectLater(notifier.restart(id), throwsA(isA<StateError>()));
      expect(container.read(sessionsDataProvider).getById(id)!.paneId, isNull);
    });

    test('a restart naming nothing is an ordinary create', () async {
      final db = seededDatabase();
      addTearDown(db.close);
      emptyStore();
      final container = await containerOver(db);

      final launched = await container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'claudeish'),
              title: 'Fresh',
              purpose: SessionPurpose.newSession,
              restartSessionId: 'no-such-row',
            ),
          );

      expect(launched.session.title, 'Fresh');
      expect(launched.session.externalSessionId, launched.session.id);
    });
  });
}
