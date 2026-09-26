import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **The app is a client of the server's data** (docs/daemon-architecture.md,
/// "Slice 1 — data through the server").
///
/// Notes, todos, preferences, the workspace (contexts, projects, checkouts,
/// saved sections), sessions (their rows, checkouts, records and the imported
/// history), and where agents run and who they run as (environments, SSH
/// hosts, trusted host keys, agent installations, saved accounts, usage
/// history) go through the server's data API (`lib/src/core/data/`,
/// `WorkspaceData`, `SessionsData`, `EnvironmentsData`, `SshHostsData`,
/// `AgentInstallationsData`, …); nothing under `lib/` opens their tables or the
/// `app_metadata` rows itself. The domains not moved yet still use the
/// database the app opens, from the files listed in [remaining] — a list that
/// only shrinks: a new file fails here, and a listed file that stopped
/// touching the database fails until it is taken off.
void main() {
  /// Every file under `lib/` still naming `databaseProvider` or `AppDatabase`,
  /// by the domain that keeps it there.
  const remaining = <String, List<String>>{
    // The bootstrap that opens the store for everything below. Goes with the
    // last domain.
    'bootstrap': [
      'main.dart',
      'src/core/database/database_providers.dart',
      'src/core/lifecycle/app_lifecycle.dart',
    ],
    'the conversation index': [
      'src/features/cli_detection/application/cli_detection_providers.dart',
      'src/features/cli_detection/data/conversation_index_dao.dart',
    ],
  };

  late Map<String, String> sources;

  setUpAll(() {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from the app root');
    sources = {
      for (final file in lib.listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart'))
          file.path.replaceAll(r'\', '/').substring('lib/'.length): _code(
            file.readAsStringSync(),
          ),
    };
  });

  Iterable<String> filesMatching(RegExp pattern) => [
    for (final entry in sources.entries)
      if (pattern.hasMatch(entry.value)) entry.key,
  ]..sort();

  test('the moved domains never reach the store from the app', () {
    expect(
      filesMatching(RegExp(r'\b(NoteDao|TodoDao)\b|karmashala_notes/store')),
      isEmpty,
      reason: 'notes and todos go through NotesRepository / TodosRepository',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(WorkspaceDao|ProjectDao|RepositoryDao|SectionDao)\b|'
          r'karmashala_projects/store|'
          r'\b(FROM|INTO|UPDATE|JOIN)\s+(workspaces|projects|repositories|'
          r'explorer_sections?|explorer_section_members)\b',
        ),
      ),
      // The index's search narrows to a project's checkouts inside its own
      // query; it moves with the conversation index (1f).
      ['src/features/cli_detection/data/conversation_index_dao.dart'],
      reason: 'the workspace goes through WorkspaceData',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(SessionDao|SessionEventDao|DecisionRecordDao|SessionRecapDao|'
          r'SessionRelayDao|FollowUpDao|SessionRepositoryDao|'
          r'ImportedSessionDao|HostedSessionStatusKeeper|'
          r'SessionLifecycleRecorder)\b|karmashala_session_engine/store',
        ),
      ),
      isEmpty,
      reason:
          'sessions and their records go through SessionsData and the '
          'sessions providers; the daemon records lifecycle status',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(FROM|INTO|UPDATE|JOIN)\s+(sessions|session_repositories|'
          r'session_events|session_decisions|session_recaps|session_relays|'
          r'session_follow_ups|imported_sessions)\b',
        ),
      ),
      // The index's own queries join the rows it indexes; it moves with the
      // conversation index (1f), reading only.
      ['src/features/cli_detection/data/conversation_index_dao.dart'],
      reason: 'sessions go through SessionsData',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(ExecutionEnvironmentDao|SshHostDao|KnownHostDao|'
          r'AgentInstallationDao|AgentInstallationRows|ClaudeAccountDao|'
          r'CodexAccountDao|UsageSampleDao)\b|karmashala_environments/store',
        ),
      ),
      isEmpty,
      reason:
          'environments, SSH hosts, trusted keys, installations, saved '
          'accounts and usage go through EnvironmentsData, SshHostsData, '
          'KnownHostsData, AgentInstallationsData and the accounts and usage '
          'data',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(PairedDeviceDao|RemoteHostService|hostDeviceIdFor)\b|'
          r'karmashala_store/devices|karmashala_companion_server/store|'
          r'\b(FROM|INTO|UPDATE|JOIN)\s+paired_devices\b',
        ),
      ),
      isEmpty,
      reason:
          'paired devices go through PairedDevicesData (no keys, no push '
          'tokens); the server alone runs the companion and keeps its host id',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(FROM|INTO|UPDATE|JOIN)\s+(execution_environments|'
          r'agent_installations|ssh_hosts|ssh_known_hosts|claude_accounts|'
          r'codex_accounts|usage_samples)\b',
        ),
      ),
      // The index's search names the agent of each hit inside its own query;
      // it moves with the conversation index (1f), reading only.
      ['src/features/cli_detection/data/conversation_index_dao.dart'],
      reason: 'environments and agents go through the server',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(AutomationDao|ScheduledResumeDao|ProjectCheckDao|CheckoutRows)'
          r'\b|karmashala_automations/store|'
          r'\b(FROM|INTO|UPDATE|JOIN)\s+(automations|automation_runs|'
          r'automation_run_checks|automation_session_origins|'
          r'scheduled_resumes|project_checks|project_verification)\b',
        ),
      ),
      isEmpty,
      reason:
          'automations, runs, checks, origins, resumes and project checks go '
          'through AutomationsData, ResumesData and ProjectChecksData',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(WorktreeSetupDao|ReviewThreadDao|CommandSnippetDao|'
          r'TerminalPresetDao)\b|karmashala_git/store|'
          r'karmashala_snippets/store|'
          r'\b(FROM|INTO|UPDATE|JOIN)\s+(worktree_setup|worktree_setup_runs|'
          r'review_threads|review_thread_comments|command_snippets|'
          r'terminal_presets)\b',
        ),
      ),
      isEmpty,
      reason:
          'worktree setups and their runs, review threads, snippets and '
          'presets go through WorktreeSetupData, ReviewThreadService, '
          'CommandSnippetsController and TerminalPresets',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(CheckpointDao|VerificationDao|ComparisonDao|'
          r'StoreCheckpointRecords|StoreVerificationRecords)\b|'
          r'karmashala_checkpoints/store|karmashala_verification/store|'
          r'karmashala_comparisons/store|'
          r'\b(FROM|INTO|UPDATE|JOIN)\s+(session_checkpoints|'
          r'session_checkpoint_files|verification_runs|verification_steps|'
          r'verification_artifacts|fanout_comparisons|fanout_candidates)\b',
        ),
      ),
      isEmpty,
      reason:
          'checkpoints, verification runs and comparisons go through '
          'CheckpointsData, VerificationData and ComparisonsData',
    );
    expect(
      filesMatching(RegExp(r'\.(readMetadata|writeMetadata)\(')),
      // The index's own write counter, a key the data API reserves for its
      // domain; it moves with the conversation index.
      ['src/features/cli_detection/data/conversation_index_dao.dart'],
      reason: 'preferences go through AppPreferences',
    );
    expect(
      [
        for (final file in filesMatching(
          RegExp(r'\b(TerminalLayoutDao|terminalLayoutDaoProvider)\b'),
        ))
          if (RegExp(
            r'\bdatabaseProvider\b|\bAppDatabase\b',
          ).hasMatch(sources[file]!))
            file,
      ],
      isEmpty,
      reason:
          'the terminal layout is this client\'s own (TerminalLayoutStore), '
          'never the server\'s store',
    );
    for (final folder in const [
      'src/features/notes/',
      'src/features/todos/',
      'src/features/settings/',
      'src/features/workspaces/',
      'src/features/projects/',
      'src/features/repositories/',
      'src/features/sessions/',
      'src/features/follow_ups/',
      'src/features/environments/',
      'src/features/ssh/',
      'src/features/agents/',
      'src/features/remote/',
      'src/features/git/',
      'src/features/snippets/',
      'src/features/checkpoints/',
      'src/features/verification/',
      'src/features/fanout/',
    ]) {
      expect(
        [
          for (final file in filesMatching(
            RegExp(r'\bdatabaseProvider\b|\bAppDatabase\b'),
          ))
            if (file.startsWith(folder)) file,
        ],
        isEmpty,
        reason: '$folder reads and writes through the server',
      );
    }
  });

  test('the app never runs the server\'s data service', () {
    expect(
      filesMatching(
        RegExp(r'\b(DataService|DataSession)\b|server/lib/src/data|src/data/'),
      ),
      isEmpty,
      reason: 'the app is a client: no server is run inside it',
    );
    expect(
      filesMatching(
        RegExp(r'\bdatabaseProvider\b|\bAppDatabase\b'),
      ).where((file) => file.startsWith('src/core/data/')),
      isEmpty,
      reason: 'the data client reaches the server, never the store',
    );
    expect(filesMatching(RegExp(r'\bAppDatabase\.open\(')), ['main.dart']);
  });

  test('no app test reaches the moved domains in a store', () {
    // Notes, todos, preferences, the workspace, sessions, environments, SSH
    // hosts, trusted keys, installations, saved accounts, usage, automations,
    // checkpoints, verification, comparisons, snippets, worktree setups,
    // review threads and paired devices are read and written through the
    // fake server (test/support/fake_data_server.dart);
    // their rules are tested in packages/karmashala_notes,
    // karmashala_projects, karmashala_session(_engine), karmashala_environments,
    // karmashala_store and server/test/data. The one exception is the
    // transitional `workspace_mirror.dart`, which copies the fake's rows into
    // the conversation index's database for the rows its queries join.
    final reaching = <String>[];
    for (final file in Directory(
      'test',
    ).listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.endsWith('guard_test.dart')) {
        continue;
      }
      if (RegExp(
        r'\b(DataService|NoteDao|TodoDao|StoredPreferences|WorkspaceDao|'
        r'ProjectDao|RepositoryDao|SectionDao|SessionDao|SessionEventDao|'
        r'DecisionRecordDao|SessionRecapDao|SessionRelayDao|FollowUpDao|'
        r'SessionRepositoryDao|ImportedSessionDao|ExecutionEnvironmentDao|'
        r'SshHostDao|KnownHostDao|AgentInstallationDao|ClaudeAccountDao|'
        r'CodexAccountDao|UsageSampleDao|WorktreeSetupDao|ReviewThreadDao|'
        r'CommandSnippetDao|TerminalPresetDao|PairedDeviceDao|CheckpointDao|'
        r'VerificationDao|ComparisonDao|AutomationDao|ScheduledResumeDao|'
        r'ProjectCheckDao)\b|karmashala_automations/store|'
        r'karmashala_checkpoints/store|karmashala_verification/store|'
        r'karmashala_comparisons/store|'
        r'karmashala_store/devices|karmashala_companion_server/store|'
        r'karmashala_environments/store|karmashala_git/store|'
        r'karmashala_snippets/store|'
        // Seeding them in a store; a cost test may still name them to count
        // that the app issues no statement against them.
        r'\b(INTO|UPDATE)\s+(execution_environments|'
        r'agent_installations|ssh_hosts|ssh_known_hosts|claude_accounts|'
        r'codex_accounts|usage_samples|automations|automation_runs|'
        r'automation_run_checks|automation_session_origins|project_checks|'
        r'project_verification|scheduled_resumes|session_checkpoints|'
        r'session_checkpoint_files|verification_runs|verification_steps|'
        r'verification_artifacts|fanout_comparisons|fanout_candidates|'
        r'command_snippets|terminal_presets|worktree_setup|'
        r'worktree_setup_runs|review_threads|review_thread_comments|'
        r'paired_devices)\b|'
        r'karmashala_session_engine/store|'
        r'karmashala_host/data\.dart|karmashala_notes/store|'
        r'karmashala_projects/store|\.(readMetadata|writeMetadata)\(|'
        r'DataClient\.inProcess',
      ).hasMatch(_code(file.readAsStringSync()))) {
        reaching.add(path);
      }
    }
    expect(reaching..sort(), ['test/support/workspace_mirror.dart']);
  });

  test('only the conversation index\'s tests open a database', () {
    // Everything else a test drives reads through the fake server; the index
    // (and the bootstrap that closes its store) moves in 1f.
    const allowed = [
      'test/app/shell/quick_open/quick_open_conversations_test.dart',
      'test/core/lifecycle/app_lifecycle_test.dart',
      'test/features/cli_detection/conversation_index_backfill_test.dart',
      'test/features/cli_detection/conversation_index_dao_test.dart',
      'test/features/cli_detection/conversation_indexer_test.dart',
      'test/features/cli_detection/session_search_benchmark_test.dart',
      'test/features/cli_detection/session_search_test.dart',
      'test/features/cli_detection/store_slot_cost_test.dart',
      'test/features/cli_detection/thinking_is_not_indexed_test.dart',
      'test/features/mcp/session_search_tool_test.dart',
      'test/features/terminal/fake_instance.dart',
      'test/support/conversation_index_database.dart',
      'test/support/workspace_mirror.dart',
    ];
    final opening = [
      for (final file in Directory(
        'test',
      ).listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') &&
            !file.path.endsWith('guard_test.dart') &&
            RegExp(
              r'\b(AppDatabase|databaseProvider)\b',
            ).hasMatch(_code(file.readAsStringSync())))
          file.path.replaceAll(r'\', '/'),
    ]..sort();
    expect(
      opening,
      allowed,
      reason:
          'a test of a moved domain seeds the fake server; one reaching the '
          'index takes conversationIndexDatabase()',
    );
  });

  test('the files still touching the database only shrink', () {
    final listed = {for (final files in remaining.values) ...files};
    final touching = filesMatching(
      RegExp(r'\bdatabaseProvider\b|\bAppDatabase\b'),
    ).toSet();
    expect(
      touching.difference(listed).toList()..sort(),
      isEmpty,
      reason:
          'a new file reaches the database: go through the data API '
          '(lib/src/core/data/) instead',
    );
    expect(
      listed.difference(touching).toList()..sort(),
      isEmpty,
      reason: 'these no longer touch the database: take them off the list',
    );
  });
}

/// [source] without `//` comments, so prose naming a DAO is not a use of it.
String _code(String source) => source
    .split('\n')
    .map((line) {
      final comment = line.indexOf('//');
      return comment == -1 ? line : line.substring(0, comment);
    })
    .join('\n');
