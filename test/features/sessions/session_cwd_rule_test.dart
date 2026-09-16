import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/temp_directory.dart';

/// Does resuming a conversation depend on the directory you resume it from?
///
/// cmux says yes for a whole family of agents — its `AgentCwdNamespacing`
/// enum splits them into `byDirectory` ("the store is keyed by a directory
/// derived from the launch cwd … resuming from a different directory looks in
/// the wrong namespace and fails with 'No conversation found'") and `cwdInFile`
/// — and this app moves sessions between directories on purpose, so the answer
/// decides whether three of our own paths are lying to the user.
///
/// **The claim was checked against the CLIs and stores installed on this
/// machine rather than inherited, and it does not hold for any of the three
/// agents we ship against.** The fixtures below are shaped exactly like the real
/// stores that were read, with the real paths named in each case so a future
/// reader can go and look again rather than trust this file:
///
/// | Agent | Store layout observed | Keyed by |
/// | --- | --- | --- |
/// | Claude Code | `~/.claude/projects/<encoded cwd>/<id>.jsonl` | the cwd — *and it resumes anyway* |
/// | Codex | `~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<id>.jsonl` | the date; cwd is a field |
/// | Antigravity | `~/.gemini/antigravity-cli/conversations/<id>.db` | nothing; flat by id |
///
/// Claude Code is the interesting one and the reason the table has a hedge in
/// it. The bucket name really is a function of the launch directory —
/// `e.replace(/[^a-zA-Z0-9]/g,"-")` in the 2.1.258 binary, confirmed against
/// eight real buckets whose recorded `cwd` encodes to exactly their own name —
/// but `--resume <id>` does not stop at that bucket. It falls back through a
/// `git worktree list` sweep of the launch directory's repository
/// (`tengu_resume_worktree_fallback`) and then a scan of *every* bucket for
/// `<id>.jsonl` (`tengu_transcript_id_scan_fallback`), both present in 2.1.252,
/// 2.1.257, 2.1.258 and the Windows `claude.exe`.
///
/// So what is pinned here is the pair of facts, not the folklore: the store
/// layout each agent actually has, and the conservative default the registry
/// keeps for the agent nobody has checked.
void main() {
  group('the store layout each agent actually has', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_cwd_'));
    tearDown(() => removeTempDirectory(tmp));

    /// `<home>/projects/<encoded cwd>/<id>.jsonl`, the shape of every bucket in
    /// the owner's own `~/.claude/projects`.
    test('Claude Code files a transcript under an encoding of its launch '
        'directory, and is found from any of them', () async {
      final home = p.join(tmp.path, '.claude');
      // Two conversations, two directories, two buckets — the encoding is the
      // one read out of the binary: every non-alphanumeric becomes a dash, so
      // `sampada_trails` and `sampada-trails` land in the same place and a path
      // comparison is strictly sharper than reproducing it. (Which is why
      // `resumeDirectoryRefusalFor` compares paths and not buckets.)
      File(
        p.join(home, 'projects', 'C--src-demo-app', 'conv-root.jsonl'),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync(r'{"type":"user","cwd":"C:\\src\\demo\\app"}' '\n');
      File(
        p.join(
          home,
          'projects',
          'C--src-.karmashala-worktrees-app-session-1',
          'conv-worktree.jsonl',
        ),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync(
          r'{"type":"user","cwd":"C:\\src\\.karmashala-worktrees\\app-session-1"}'
          '\n',
        );

      // The bucket is not an index anybody has to guess: both conversations
      // answer `present` from one probe that scans every bucket, which is the
      // same resolution the CLI's own id scan performs.
      for (final id in ['conv-root', 'conv-worktree']) {
        expect(
          await const ConversationStoreIndex().presenceOf(
            storeHome: home,
            format: AgentStoreFormat.claudeJsonl,
            conversationId: id,
          ),
          ConversationPresence.present,
          reason: '$id must be findable without knowing which bucket holds it',
        );
      }
    });

    /// `<home>/sessions/<Y>/<M>/<D>/rollout-<timestamp>-<id>.jsonl`, with the
    /// cwd inside the first line's `session_meta` — copied from
    /// `~/.codex/sessions/2026/07/31/rollout-2026-07-31T07-46-11-…jsonl`.
    test('Codex files a rollout by date and records the cwd inside it',
        () async {
      final home = p.join(tmp.path, '.codex');
      const id = '019fb5e7-6f41-75f2-83ce-7f5fe5176483';
      final file = File(
        p.join(
          home,
          'sessions',
          '2026',
          '07',
          '31',
          'rollout-2026-07-31T07-46-11-$id.jsonl',
        ),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"timestamp":"2026-07-31T02:02:43.404Z","type":"session_meta",'
          '"payload":{"session_id":"$id","cwd":"/mnt/c/src/demo",'
          '"originator":"codex-tui"}}\n',
        );

      // Nothing in the path names a directory…
      expect(p.split(file.path), isNot(contains('demo')));
      // …and the directory that *is* recorded is content, not a key.
      expect(file.readAsStringSync(), contains('"cwd":"/mnt/c/src/demo"'));
      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home,
          format: AgentStoreFormat.codexRollout,
          conversationId: id,
        ),
        ConversationPresence.present,
      );
    });

    /// `<home>/conversations/<id>.db` — flat — beside a
    /// `cache/last_conversations.json` that is the *only* directory key in the
    /// store, and is what `--continue` resolves through rather than
    /// `--conversation`.
    test('Antigravity files a conversation flat by id, and keys only '
        '--continue by directory', () async {
      final home = p.join(tmp.path, '.gemini', 'antigravity-cli');
      const id = '0dee27dc-09be-4a00-bca7-5fa6d10fe285';
      File(p.join(home, 'conversations', '$id.db'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File(p.join(home, 'cache', 'last_conversations.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(r'{"C:\\src\\demo\\app": "' '$id"}');

      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home,
          format: AgentStoreFormat.antigravityStore,
          conversationId: id,
        ),
        ConversationPresence.present,
      );
      // The claim being pinned is the split: the id addresses the file, the
      // directory addresses only the "latest here" map.
      expect(
        Directory(
          p.join(home, 'conversations'),
        ).listSync().map((entity) => p.basename(entity.path)),
        ['$id.db'],
      );
    });
  });

  group('what the registry declares about it', () {
    AgentDescriptor byId(String id) {
      final descriptor = AgentRegistry.builtIn.byId(id);
      expect(descriptor, isNotNull, reason: '$id must still be a built-in');
      return descriptor!;
    }

    for (final id in [AgentIds.claudeCode, AgentIds.codex, 'antigravity']) {
      test('$id resumes from any directory, and says where that was checked',
          () {
        final locality = byId(id).launch.resumeLocality;
        expect(locality.findsConversationAnywhere, isTrue);
        // Evidence is the contract every other verified capability on this
        // descriptor holds itself to; a claim nobody can re-check is folklore.
        expect(locality.evidence, isNotEmpty);
      });
    }

    test('no built-in claims one without saying where it was checked', () {
      // The rule is about the *claim*, not the field. A descriptor that says a
      // conversation is findable from anywhere is making an assertion about a
      // CLI's storage, and folklore is what evidence exists to keep out. The
      // safe side needs no evidence: `findsConversationAnywhere: false` is what
      // an unfilled `AgentLaunchSpec` already means (the case below), which is
      // where an agent nobody has checked belongs.
      for (final descriptor in builtInAgentDescriptors) {
        if (!descriptor.launch.resumeLocality.findsConversationAnywhere) {
          continue;
        }
        expect(
          descriptor.launch.resumeLocality.evidence,
          isNotEmpty,
          reason: '${descriptor.id} must state what was checked',
        );
      }
    });

    test('an agent nobody has checked is assumed to be cwd-keyed', () {
      const unchecked = AgentLaunchSpec();
      expect(unchecked.resumeLocality.findsConversationAnywhere, isFalse);
      expect(unchecked.resumeLocality.evidence, isEmpty);
    });
  });

  group('resumeDirectoryCaveatFor', () {
    const verified = AgentDescriptor(
      id: 'verifiedCli',
      displayName: 'Verified CLI',
      binaries: AgentBinaries(windows: ['verified'], posix: ['verified']),
      launch: AgentLaunchSpec(
        interactiveResume: AgentResume.flag('--resume'),
        resumeLocality: AgentResumeLocality.anyDirectory(
          evidence: 'a test that says so',
        ),
      ),
    );
    const unchecked = AgentDescriptor(
      id: 'uncheckedCli',
      displayName: 'Unchecked CLI',
      binaries: AgentBinaries(windows: ['unchecked'], posix: ['unchecked']),
      launch: AgentLaunchSpec(interactiveResume: AgentResume.flag('--resume')),
    );
    const registry = AgentRegistry([verified, unchecked]);

    String? caveat(
      String cli, {
      String? recorded,
      String? launch,
      String? id = 'conv-1',
    }) => resumeDirectoryCaveatFor(
      registry,
      cli,
      id,
      recordedDirectory: recorded,
      launchDirectory: launch,
    );

    test('a directory that did not move says nothing', () {
      expect(
        caveat('uncheckedCli', recorded: r'C:\src\a', launch: r'C:\src\a'),
        isNull,
      );
    });

    test('trailing separators are not a move', () {
      expect(
        caveat('uncheckedCli', recorded: r'C:\src\a\', launch: r'C:\src\a'),
        isNull,
      );
    });

    test('case is a move, because two directories that differ only in case '
        'are two directories', () {
      expect(
        caveat('uncheckedCli', recorded: '/src/Work', launch: '/src/work'),
        isNotNull,
      );
    });

    test('a move earns a sentence for an agent nobody has checked, naming '
        'both directories and the conversation', () {
      final message = caveat(
        'uncheckedCli',
        recorded: r'C:\src\.karmashala-worktrees\app-s1',
        launch: r'C:\src\demo\app',
      );
      expect(message, isNotNull);
      expect(message, contains(r'C:\src\.karmashala-worktrees\app-s1'));
      expect(message, contains(r'C:\src\demo\app'));
      expect(message, contains('Unchecked CLI'));
      expect(message, contains('conv-1'));
    });

    test('the same move says nothing for an agent that was checked', () {
      expect(
        caveat(
          'verifiedCli',
          recorded: r'C:\src\.karmashala-worktrees\app-s1',
          launch: r'C:\src\demo\app',
        ),
        isNull,
      );
    });

    test('an unknown directory says nothing', () {
      expect(caveat('uncheckedCli', recorded: r'C:\src\a'), isNull);
      expect(caveat('uncheckedCli', launch: r'C:\src\a'), isNull);
      expect(caveat('uncheckedCli'), isNull);
    });

    test('no conversation named, nothing to be wrong about', () {
      expect(
        caveat(
          'uncheckedCli',
          id: null,
          recorded: r'C:\src\a',
          launch: r'C:\src\b',
        ),
        isNull,
      );
    });

    test('an agent the registry never heard of is left to resumeRefusalFor, '
        'which is a certainty and does refuse', () {
      // This function says nothing — there is no descriptor to read a locality
      // off — and it does not need to: "no resume convention at all" is the
      // certain half of the pair, and it still stops the command.
      expect(
        caveat('mysteryCli', recorded: r'C:\src\a', launch: r'C:\src\b'),
        isNull,
      );
      expect(resumeRefusalFor(registry, 'mysteryCli', 'conv-1'), isNotNull);
    });
  });

  group('the paths that move a session', () {
    // Two agents, identical but for the one field: whether anybody has checked
    // that its resume survives a change of directory.
    const uncheckedAgent = AgentDescriptor(
      id: 'roverCli',
      displayName: 'Rover CLI',
      binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
      launch: AgentLaunchSpec(
        permission: testPermissionSupport,
        resume: AgentResume.flag('--resume'),
        interactiveResume: AgentResume.flag('--resume'),
        fork: AgentForkSupport.native(
          resume: AgentResume.flag('--resume'),
          extraArguments: ['--fork-session'],
          evidence: 'a test that says so',
        ),
      ),
    );
    const checkedAgent = AgentDescriptor(
      id: 'roverCli',
      displayName: 'Rover CLI',
      binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
      launch: AgentLaunchSpec(
        permission: testPermissionSupport,
        resume: AgentResume.flag('--resume'),
        interactiveResume: AgentResume.flag('--resume'),
        resumeLocality: AgentResumeLocality.anyDirectory(
          evidence: 'a test that says so',
        ),
        fork: AgentForkSupport.native(
          resume: AgentResume.flag('--resume'),
          extraArguments: ['--fork-session'],
          evidence: 'a test that says so',
        ),
      ),
    );

    ({ProviderContainer container, AppDatabase db}) harness({
      required AgentDescriptor agent,
      Set<String> missingDirectories = const {},
    }) {
      final db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation(agentId: 'roverCli'));
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
          agentRegistryProvider.overrideWithValue(AgentRegistry([agent])),
          settingsControllerProvider.overrideWith(
            () => _StaticSettings(const Settings()),
          ),
          sessionDirectoryPresentProvider.overrideWithValue(
            (directory) => !missingDirectories.contains(directory.path),
          ),
          // Nothing may shell out: worktree creation goes through a fake git.
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
          ),
          hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        ],
      );
      return (container: container, db: db);
    }

    const worktreePath = r'C:\src\.karmashala-worktrees\app-s1';

    /// A stopped session whose worktree has been archived away: the row and its
    /// conversation survive, the directory does not. This is exactly what
    /// `SessionArchiveService` leaves behind — it removes the worktree and
    /// deliberately keeps everything else.
    void insertArchivedWorktreeSession(AppDatabase db) {
      SessionDao(db).insert(
        Session(
          id: 'src-1',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Source',
          useWorktree: true,
          worktree: const EnvironmentPath(
            environmentId: 'windows',
            path: worktreePath,
          ),
          workingDirectory: const EnvironmentPath(
            environmentId: 'windows',
            path: worktreePath,
          ),
          externalSessionId: 'conv-1',
          status: SessionStatus.completed,
          createdAt: testTime,
        ),
      );
    }

    test('archived worktree → the resume still happens, and says the '
        'conversation may not come with it', () async {
      final h = harness(
        agent: uncheckedAgent,
        missingDirectories: {worktreePath},
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      insertArchivedWorktreeSession(h.db);

      final result = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'resume',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'conv-1',
            ),
          );
      // Both halves of the substitution in one line: the directory that went
      // away, and what that may cost the conversation. A refusal was the other
      // candidate and is the wrong answer — an archived worktree would then
      // mean the session could never be opened again.
      expect(result.workingDirectoryNotice, contains(worktreePath));
      expect(result.workingDirectoryNotice, contains(r'C:\src\demo\app'));
      expect(
        result.workingDirectoryNotice,
        contains('may open a new conversation'),
      );
      expect(result.workingDirectoryNotice, contains('conv-1'));
    });

    test('the same resume says only what the fallback says, for an agent that '
        'was checked', () async {
      final h = harness(agent: checkedAgent, missingDirectories: {worktreePath});
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      insertArchivedWorktreeSession(h.db);

      final result = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'resume',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'conv-1',
            ),
          );
      // The honest half that already existed, and nothing invented on top of
      // it: this agent was checked, so there is no caveat to add.
      expect(result.workingDirectoryNotice, contains(worktreePath));
      expect(
        result.workingDirectoryNotice,
        isNot(contains('may open a new conversation')),
      );
    });

    test('fork into a new worktree says so for an agent nobody has checked',
        () async {
      final h = harness(agent: uncheckedAgent);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      insertArchivedWorktreeSession(h.db);

      final result = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'fork',
              purpose: SessionPurpose.newSession,
              forkExternalSessionId: 'conv-1',
              useWorktree: true,
            ),
          );
      // Nothing "went away" here — the app chose a new directory — so there is
      // no fallback notice, and the caveat is the whole message.
      expect(result.session.worktree, isNotNull);
      expect(
        result.workingDirectoryNotice,
        contains('may open a new conversation'),
      );
      expect(result.workingDirectoryNotice, contains(worktreePath));
    });

    test('fork into a new worktree says nothing for an agent that was checked',
        () async {
      final h = harness(agent: checkedAgent);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      insertArchivedWorktreeSession(h.db);

      final result = await h.container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'roverCli'),
              title: 'fork',
              purpose: SessionPurpose.newSession,
              forkExternalSessionId: 'conv-1',
              useWorktree: true,
            ),
          );
      expect(result.session.worktree, isNotNull);
      expect(result.workingDirectoryNotice, isNull);
      // A fork is a create: the source conversation is left where it is, and
      // the row that named it is untouched.
      expect(SessionDao(h.db).getById('src-1')!.worktree!.path, worktreePath);
    });

    /// The third suspect, cleared. `select_checkout` was listed alongside
    /// archiving and handoff as a way an agent could move a session's checkout;
    /// it is not one. It writes the Explorer's selection and the followed
    /// session's remembered pick, and no session row.
    test('select_checkout moves the view, never a session directory', () {
      final h = harness(agent: checkedAgent);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      insertArchivedWorktreeSession(h.db);
      RepositoryDao(h.db).insert(repository(id: 'r2', name: 'api'));

      final before = SessionDao(h.db).getById('src-1')!;
      h.container.read(checkoutPickerProvider).select(repository(id: 'r2'));
      final after = SessionDao(h.db).getById('src-1')!;

      expect(after.workingDirectory, before.workingDirectory);
      expect(after.worktree, before.worktree);
    });
  });
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}
