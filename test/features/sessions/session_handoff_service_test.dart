import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/handoff_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_chat_source.dart';
import 'package:chitragupta/src/features/sessions/application/session_handoff_service.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/handoff_action.dart';
import 'package:chitragupta/src/features/sessions/domain/session_fork.dart';
import 'package:chitragupta/src/features/sessions/domain/session_lineage.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';

/// Two agents that differ in exactly the ways the handoff cares about: one
/// forks natively and takes a prompt, the other cannot be told anything.
const _forker = AgentDescriptor(
  id: 'forker',
  displayName: 'Forker CLI',
  binaries: AgentBinaries(windows: ['forker'], posix: ['forker']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
      PermissionMode.bypass: PermissionModeMapping.exact(['--trust-me']),
    },
    interactiveResume: AgentResume.flag('--resume'),
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    acceptsPromptArgument: true,
    fork: AgentForkSupport.native(
      resume: AgentResume.flag('--resume'),
      extraArguments: ['--fork-session'],
      evidence: 'forker --help',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.forker',
    format: AgentStoreFormat.claudeJsonl,
  ),
);

const _mute = AgentDescriptor(
  id: 'mute',
  displayName: 'Mute CLI',
  binaries: AgentBinaries(windows: ['mute'], posix: ['mute']),
  // Takes no prompt argument and declares no fork: the shape Antigravity has.
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.bypass: PermissionModeMapping.exact(['--yolo']),
    },
  ),
);

class _FakeLocator implements SessionTranscriptLocator {
  _FakeLocator(this.path);
  final String? path;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => path;
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;
  @override
  Settings build() => _settings;
}

typedef Harness = ({ProviderContainer container, AppDatabase db});

Harness harness({
  String? transcriptPath,
  HandoffRepoState? repoState = const HandoffRepoState(
    branch: 'feature/x',
    hasRemote: true,
    defaultBranch: 'main',
    commitsAhead: 3,
  ),
  String gitStatus = ' M lib/a.dart\nA  lib/b.dart\n?? notes.txt\n',
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db)
    ..insert(agentInstallation(id: 'a1', agentId: 'forker'))
    ..insert(agentInstallation(id: 'a2', agentId: 'mute'));

  final git = FakeCommandRunner(
    responder: (request) => CommandResult(
      exitCode: 0,
      stdout: request.arguments.contains('status') ? gitStatus : '',
      stderr: '',
    ),
  );

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([_forker, _mute]),
      ),
      settingsControllerProvider.overrideWith(
        () => _StaticSettings(const Settings()),
      ),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: git),
      ),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      sessionTranscriptLocatorProvider.overrideWithValue(
        _FakeLocator(transcriptPath),
      ),
      // Overridden rather than driven through `gh`: the packet's job is to say
      // what it was told, and what git state *reaches* it is the git feature's
      // test, not this one's.
      sessionHandoffStateProvider.overrideWith((ref, id) async => repoState),
    ],
  );
  return (container: container, db: db);
}

/// A Claude-shaped transcript on disk, so the real reader parses it.
String writeTranscript(List<(String, String)> turns) {
  final dir = Directory.systemTemp.createTempSync('handoff-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/session.jsonl');
  file.writeAsStringSync(
    turns
        .map(
          (turn) => jsonEncode({
            'type': turn.$1 == 'user' ? 'user' : 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': turn.$2},
              ],
            },
          }),
        )
        .join('\n'),
  );
  return file.path;
}

void seedSession(
  AppDatabase db, {
  String id = 'src',
  String installationId = 'a1',
  String? externalSessionId = 'cli-1',
}) {
  SessionDao(db).insert(
    session(id: id, agentInstallationId: installationId).copyWith(
      externalSessionId: externalSessionId,
      permissionMode: PermissionMode.ask,
    ),
  );
}

void main() {
  group('targets', () {
    test('offers every installed agent, marking the one already running it', () {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final targets = h.container
          .read(sessionHandoffServiceProvider)
          .targetsFor('src');
      expect(targets.map((t) => t.agentName), ['Forker CLI', 'Mute CLI']);
      // The same agent is offered too: "continue this in a fresh session" is a
      // real answer to a full context window.
      expect(targets.first.isSameAgent, isTrue);
      expect(targets.last.isSameAgent, isFalse);
    });

    test('refuses a target that cannot be handed an opening prompt', () {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final mute = h.container
          .read(sessionHandoffServiceProvider)
          .targetsFor('src')
          .firstWhere((t) => t.agentName == 'Mute CLI');
      expect(mute.canReceive, isFalse);
      expect(mute.refusal, contains('takes no opening prompt'));
      // The packet would have been silently dropped, and the new session would
      // have started knowing nothing at all.
      expect(mute.refusal, contains('knowing nothing'));
    });

    test('carries the session mode, refusing to escalate it', () {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final mute = h.container
          .read(sessionHandoffServiceProvider)
          .targetsFor('src')
          .firstWhere((t) => t.agentName == 'Mute CLI');
      // Mute's only expressible mode is bypass, and the session is on `ask`.
      expect(mute.permission.mode, PermissionMode.ask);
      expect(mute.permission.enforced, isFalse);
    });

    test(
      'a session that no longer exists offers nothing rather than throwing',
      () {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        expect(
          h.container.read(sessionHandoffServiceProvider).targetsFor('gone'),
          isEmpty,
        );
      },
    );
  });

  group('the packet', () {
    test('quotes the transcript, names both agents and lists the tree', () async {
      final path = writeTranscript([
        ('user', 'Parse the header.'),
        ('agent', 'Done, in lib/a.dart.'),
      ]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
            unresolvedTasks: const ['write the tests', '  '],
          );
      final text = packet.render();

      expect(text, contains('# Handed off from Forker CLI'));
      expect(text, contains('**You are:** Mute CLI'));
      // The agent's own turn is attributed to it by name, never to "assistant".
      expect(text, contains('**Forker CLI:**'));
      expect(text, contains('> Done, in lib/a.dart.'));
      expect(text, contains('**The user:**'));
      // Working tree, read through the real git status parser.
      expect(text, contains('lib/a.dart'));
      expect(text, contains('lib/b.dart'));
      expect(text, contains('notes.txt'));
      expect(text, contains('`feature/x` — 3 commits ahead of `origin/main`'));
      // Blank task lines are dropped rather than rendered as empty checkboxes.
      expect(text, contains('- [ ] write the tests'));
      expect('- [ ] '.allMatches(text).length, 1);
      expect(text, endsWith('Finish it.'));
    });

    test('a transcript that cannot be located is stated, not faked', () async {
      final h = harness(transcriptPath: null);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
          );
      expect(packet.recap, isEmpty);
      expect(packet.render(), contains('Nothing was said in that session yet'));
    });

    test('git refusing to answer is an admission, not a clean tree', () async {
      final h = harness(repoState: null);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
          );
      expect(packet.render(), contains('unknown (git could not be asked)'));
    });
  });

  group('handing off', () {
    Future<void> expectLaunched(
      Harness h, {
      required String childId,
      required SessionLink link,
    }) async {
      final child = SessionDao(h.db).getById(childId)!;
      expect(child.parentSessionId, 'src');
      expect(child.parentLink, link);
      // The old session is untouched — not ended, not detached, not marked.
      expect(SessionDao(h.db).getById('src')!.status, session().status);
    }

    test('starts the target through the launcher and links the two', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take it from here.',
          );
      await expectLaunched(
        h,
        childId: result.session.id,
        link: SessionLink.handoff,
      );

      // The packet arrived as the opening prompt, through the one launch path.
      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments.last, contains('Handed off from Forker CLI'));
      expect(launch.arguments.last, endsWith('Take it from here.'));
      // The session's own mode travelled with it.
      expect(launch.arguments, contains('--careful'));
    });

    test('refuses a target that cannot receive the packet', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      await expectLater(
        h.container
            .read(sessionHandoffServiceProvider)
            .handoffTo(
              sessionId: 'src',
              targetInstallationId: 'a2',
              instruction: 'Take over.',
            ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('takes no opening prompt'),
          ),
        ),
      );
      // Nothing was created for a launch that must not happen.
      expect(SessionDao(h.db).getAll(), hasLength(1));
    });

    test(
      'refuses an empty instruction, saying why it is the user\'s part',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db);

        await expectLater(
          h.container
              .read(sessionHandoffServiceProvider)
              .handoffTo(
                sessionId: 'src',
                targetInstallationId: 'a1',
                instruction: '   ',
              ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('only you can write'),
            ),
          ),
        );
      },
    );
  });

  group('forking', () {
    test(
      'a native fork runs the CLI\'s own fork arguments, not a packet',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db);

        final service = h.container.read(sessionHandoffServiceProvider);
        expect(service.forkPlanFor('src').kind, SessionForkKind.native);

        final result = await service.forkSession(sessionId: 'src');
        final child = SessionDao(h.db).getById(result.session.id)!;
        expect(child.parentLink, SessionLink.fork);
        expect(child.title, 'Work (fork)');

        final launch = h.container
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(result.paneId!)!
            .agentLaunch!;
        expect(
          launch.arguments,
          containsAllInOrder(['--resume', 'cli-1', '--fork-session']),
        );
        // No id of ours is offered: the CLI is being asked to mint a new one,
        // and naming the old one alongside would contradict that.
        expect(launch.arguments, isNot(contains('--session-id')));
      },
    );

    test('a second fork of the same conversation is numbered', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);
      final service = h.container.read(sessionHandoffServiceProvider);
      await service.forkSession(sessionId: 'src');
      final second = await service.forkSession(sessionId: 'src');
      expect(
        SessionDao(h.db).getById(second.session.id)!.title,
        'Work (fork 2)',
      );
    });

    test(
      'a conversation with no CLI id degrades to a handoff, and says so',
      () async {
        final path = writeTranscript([('user', 'hello')]);
        final h = harness(transcriptPath: path);
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db, externalSessionId: null);

        final service = h.container.read(sessionHandoffServiceProvider);
        final plan = service.forkPlanFor('src');
        expect(plan.kind, SessionForkKind.handoff);
        expect(plan.explanation, contains('never learned its id for this one'));

        final result = await service.forkSession(sessionId: 'src');
        final child = SessionDao(h.db).getById(result.session.id)!;
        // Still a fork in the lineage — that is what the user asked for and got.
        expect(child.parentLink, SessionLink.fork);

        final launch = h.container
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(result.paneId!)!
            .agentLaunch!;
        expect(launch.arguments, isNot(contains('--fork-session')));
        // And the packet frames it as a branch, not a takeover.
        expect(launch.arguments.last, contains('Forked from Forker CLI'));
        expect(
          launch.arguments.last,
          contains('original session still exists'),
        );
      },
    );

    test(
      'an agent that declares no fork is refused before anything runs',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db, installationId: 'a2');

        await expectLater(
          h.container
              .read(sessionHandoffServiceProvider)
              .forkSession(sessionId: 'src'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('no verified way to fork'),
            ),
          ),
        );
        expect(SessionDao(h.db).getAll(), hasLength(1));
      },
    );
  });
}
