import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **The app is a client of the server's data** (docs/daemon-architecture.md,
/// "Slice 1 — data through the server").
///
/// Every domain — notes, todos, preferences, the workspace, sessions and
/// their records, environments and agents, automations, checkpoints,
/// verification, comparisons, the git side tables, snippets, pairings and the
/// conversation index — goes through the server's data API
/// (`lib/src/core/data/` and each feature's `*Data`); the app opens no
/// database of the server's, and imports no `karmashala_store`. Its one store
/// of its own is the terminal layout (`TerminalLayoutStore`, client-local).
void main() {
  /// Files under `lib/` allowed to name `databaseProvider` or the store's
  /// database class ([_database], spelled so this file is not one of them).
  /// Empty since slice 1f, and asserted so.
  const remaining = <String>[];

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
      isEmpty,
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
      isEmpty,
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
      isEmpty,
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
      isEmpty,
      reason: 'preferences go through AppPreferences',
    );
    expect(
      filesMatching(
        RegExp(
          r'\b(ConversationIndexDao|ConversationIndexer|SessionSearchService|'
          r'ConversationIndexBackfill)\b|karmashala_conversations/store|'
          r'\b(FROM|INTO|UPDATE|JOIN)\s+(conversation_turns|'
          r'conversation_turns_fts|conversation_turns_vocab|'
          r'conversation_index_state)\b',
        ),
      ),
      isEmpty,
      reason:
          'the conversation index is the server\'s: search, catch-up, turns '
          'and status go through ConversationSearch',
    );
    expect(
      filesMatching(RegExp(r'package:karmashala_store/')),
      isEmpty,
      reason: 'the app opens no store of the server\'s, and imports none',
    );
    expect(
      [
        for (final file in filesMatching(
          RegExp(r'\b(TerminalLayoutDao|terminalLayoutDaoProvider)\b'),
        ))
          if (RegExp(
            r'\bdatabaseProvider\b|\b' + _database + r'\b',
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
            RegExp(r'\bdatabaseProvider\b|\b' + _database + r'\b'),
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
        RegExp(r'\bdatabaseProvider\b|\b' + _database + r'\b'),
      ).where((file) => file.startsWith('src/core/data/')),
      isEmpty,
      reason: 'the data client reaches the server, never the store',
    );
    expect(filesMatching(RegExp(r'\b' + _database + r'\.open\(')), isEmpty);
  });

  test('no app test reaches the moved domains in a store', () {
    // Notes, todos, preferences, the workspace, sessions, environments, SSH
    // hosts, trusted keys, installations, saved accounts, usage, automations,
    // checkpoints, verification, comparisons, snippets, worktree setups,
    // review threads and paired devices are read and written through the
    // fake server (test/support/fake_data_server.dart);
    // their rules are tested in packages/karmashala_notes,
    // karmashala_projects, karmashala_session(_engine), karmashala_environments,
    // karmashala_conversations, karmashala_store and server/test/data.
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
        r'ProjectCheckDao|ConversationIndexDao|ConversationIndexer|'
        r'SessionSearchService)\b|karmashala_automations/store|'
        r'karmashala_conversations/store|package:karmashala_store/|'
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
    expect(reaching..sort(), isEmpty);
  });

  test('no app test opens a database', () {
    // Everything a test drives reads through the fake server
    // (test/support/fake_data_server.dart); the store's own tests live in
    // packages/karmashala_store, the index's in karmashala_conversations.
    final opening = [
      for (final file in Directory(
        'test',
      ).listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') &&
            !file.path.endsWith('guard_test.dart') &&
            RegExp(
              r'\b(' + _database + r'|databaseProvider)\b',
            ).hasMatch(_code(file.readAsStringSync())))
          file.path.replaceAll(r'\', '/'),
    ]..sort();
    expect(
      opening,
      isEmpty,
      reason: 'a test of a server domain seeds the fake server',
    );
  });

  test('the app opens no database', () {
    expect(remaining, isEmpty, reason: 'the list only ever shrank to this');
    expect(
      filesMatching(RegExp(r'\bdatabaseProvider\b|\b' + _database + r'\b')),
      remaining,
      reason:
          'a file reaches the server\'s database: go through the data API '
          '(lib/src/core/data/) instead',
    );
  });
}

/// The store's database class, written so `grep -w` over the app finds only
/// the files that use it — none since slice 1f — and not this guard.
const _database =
    'App'
    'Database';

/// [source] without `//` comments, so prose naming a DAO is not a use of it.
String _code(String source) => source
    .split('\n')
    .map((line) {
      final comment = line.indexOf('//');
      return comment == -1 ? line : line.substring(0, comment);
    })
    .join('\n');
