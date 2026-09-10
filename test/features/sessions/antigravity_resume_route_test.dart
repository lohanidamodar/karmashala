import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:agent_cli/read.dart';

/// "No resumable CLI session id could be found."
///
/// One sentence for several different situations, and the owner hit it on an
/// Antigravity session that could in fact be continued: `agy` records the
/// conversation each directory last used, in the same file it resolves
/// `--continue` through. `planAntigravityResume` turns that one refusal into
/// four answers, and this is the wiring that lets the two surfaces reach it —
/// the design note
///
/// The plan's own rules are tested in `antigravity_session_resume_test.dart`.
/// What is tested here is that clicking a stopped Antigravity card, and opening
/// one in a system terminal, now go through it.

const _repoPath = r'C:\src\demo\app';
const _conversation = 'df3c0708-1111-4222-8333-444455556666';

class _RecordingTerminals extends SystemTerminalService {
  _RecordingTerminals() : super(_DeadRunner());

  final launches = <List<String>>[];

  @override
  Future<void> launch(
    SystemTerminal terminal, {
    required List<String> command,
    String? workingDirectory,
  }) async {
    launches.add(command);
  }
}

class _DeadRunner implements CommandRunner {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no process should be started');
}

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

const _terminal = SystemTerminal(
  kind: SystemTerminalKind.windowsTerminal,
  label: 'Windows Terminal',
  executable: 'wt.exe',
);

void main() {
  late Directory tmp;
  late String storeHome;
  late AppDatabase db;
  late _RecordingTerminals terminals;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_agy_resume_');
    storeHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.antigravity, path: r'C:\bin\agy.exe'),
    );
    terminals = _RecordingTerminals();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        systemTerminalServiceProvider.overrideWithValue(terminals),
        sessionDirectoryPresentProvider.overrideWithValue((_) => true),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        cliStoreLocatorProvider.overrideWithValue(
          FixedLocator([
            CliStore(
              environmentId: 'windows',
              homesByAgentId: {AgentIds.antigravity: storeHome},
            ),
          ]),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open.
    }
  });

  void writeLastConversations(Map<String, String> byDirectory) {
    File(p.join(storeHome, 'cache', 'last_conversations.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(byDirectory));
  }

  /// A stopped Antigravity session with no CLI id — what every app-launched
  /// Antigravity session used to become the moment its pane died.
  void insertPhantom({String id = 'phantom', String? externalId}) {
    SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'New session',
        useWorktree: false,
        workingDirectory: const EnvironmentPath(
          environmentId: 'windows',
          path: _repoPath,
        ),
        status: SessionStatus.completed,
        createdAt: testTime,
        externalSessionId: externalId,
      ),
    );
  }

  group('clicking the card', () {
    test('continues the conversation the store names for the directory', () async {
      writeLastConversations({_repoPath: _conversation});
      insertPhantom();

      final result = await container
          .read(explorerActionsProvider)
          .openNative('phantom');

      expect(result.outcome, ExplorerOutcome.resumed);
      // Named, not merely opened: the app says which conversation it is about
      // to continue before continuing it.
      expect(result.message, contains(_conversation));
      // And the row is no longer a phantom, so the *next* click is an ordinary
      // resume of a row that knows its own conversation.
      expect(SessionDao(db).getById('phantom')!.externalSessionId, _conversation);
    });

    test('says there is nothing to continue when the store names none', () async {
      writeLastConversations({r'C:\elsewhere': _conversation});
      insertPhantom();

      final result = await container
          .read(explorerActionsProvider)
          .openNative('phantom');

      expect(result.outcome, ExplorerOutcome.selected);
      expect(result.message, contains(_repoPath));
      expect(result.message, isNot(contains('No resumable CLI session id')));
      expect(SessionDao(db).getById('phantom')!.externalSessionId, isNull);
    });

    test('refuses when another session already holds that conversation', () async {
      writeLastConversations({_repoPath: _conversation});
      insertPhantom(id: 'held', externalId: _conversation);
      insertPhantom();

      final result = await container
          .read(explorerActionsProvider)
          .openNative('phantom');

      expect(result.outcome, ExplorerOutcome.selected);
      expect(result.message, contains('another session'));
      expect(SessionDao(db).getById('phantom')!.externalSessionId, isNull);
    });

    test('an agent whose store says nothing keeps the old words', () async {
      // Claude Code has no "latest conversation here" notion to fall back on,
      // and inventing one would be the recency guess this registry refuses.
      AgentInstallationDao(db).insert(
        agentInstallation(id: 'a2', agentId: AgentIds.claudeCode),
      );
      SessionDao(db).insert(
        Session(
          id: 'claude-phantom',
          repositoryId: 'r1',
          agentInstallationId: 'a2',
          title: 'New session',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: testTime,
        ),
      );

      final result = await container
          .read(explorerActionsProvider)
          .openNative('claude-phantom');

      expect(result.outcome, ExplorerOutcome.selected);
      expect(result.message, contains('No resumable CLI session id'));
    });
  });

  group('opening it in a system terminal', () {
    test('finds the conversation, then actually continues it', () async {
      // Two things at once, and both matter. The store *does* name the
      // conversation, so the row stops being a phantom — and the command now
      // says which one, because `resumeCommandLine` reads the descriptor's
      // `interactiveResume` (`--conversation` for `agy`) instead of a
      // hard-coded switch on claudeCode/codex.
      //
      // This test used to assert a refusal. That refusal was the stopgap for
      // exactly this builder: for `agy` it produced the bare executable, which
      // in a terminal starts a NEW conversation under this session's name. With
      // the builder reading the registry there is nothing left to refuse here,
      // and refusing would now be the wrong answer.
      writeLastConversations({_repoPath: _conversation});
      insertPhantom();

      await container
          .read(sessionActionsProvider)
          .openSessionInSystemTerminal('phantom', _terminal);

      expect(terminals.launches.single, [
        r'C:\bin\agy.exe',
        '--conversation',
        _conversation,
      ]);
      expect(
        SessionDao(db).getById('phantom')!.externalSessionId,
        _conversation,
      );
    });

    test('refuses in the store\'s own words, not the generic one', () async {
      writeLastConversations({r'C:\elsewhere': _conversation});
      insertPhantom();

      await expectLater(
        container
            .read(sessionActionsProvider)
            .openSessionInSystemTerminal('phantom', _terminal),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(_repoPath),
              isNot(contains('No resumable CLI session id')),
            ),
          ),
        ),
      );
      expect(terminals.launches, isEmpty);
    });
  });
}
