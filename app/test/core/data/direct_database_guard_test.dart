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
    'pairings and the companion host id': [
      'src/features/remote/application/remote_providers.dart',
    ],
    'automations, checkpoints, verification, comparisons': [
      'src/features/automations/application/automation_providers.dart',
      'src/features/automations/application/scheduled_resume_providers.dart',
      'src/features/checkpoints/application/checkpoint_providers.dart',
      'src/features/verification/application/verification_providers.dart',
      'src/features/fanout/application/comparison_providers.dart',
      'src/features/fanout/data/comparison_dao.dart',
    ],
    'git: worktrees and review threads': [
      'src/features/git/application/review_threads.dart',
      'src/features/git/application/worktree_cleanup_providers.dart',
      'src/features/git/application/worktree_setup_providers.dart',
      'src/features/git/data/review_thread_dao.dart',
    ],
    'terminal layout, presets and snippets': [
      'src/features/terminal/application/terminal_layout_providers.dart',
      'src/features/terminal/application/terminal_presets.dart',
      'src/features/snippets/application/snippet_providers.dart',
      'src/features/snippets/data/command_snippet_dao.dart',
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
      filesMatching(RegExp(r'\.(readMetadata|writeMetadata)\(')),
      // The index's own write counter, a key the data API reserves for its
      // domain; it moves with the conversation index.
      ['src/features/cli_detection/data/conversation_index_dao.dart'],
      reason: 'preferences go through AppPreferences',
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
    // hosts, trusted keys, installations, saved accounts and usage are read
    // and written through the fake server (test/support/fake_data_server.dart);
    // their rules are tested in packages/karmashala_notes,
    // karmashala_projects, karmashala_session(_engine), karmashala_environments,
    // karmashala_store and server/test/data. The one exception is the
    // transitional `workspace_mirror.dart`, which copies the fake's rows into
    // a test's database for the foreign keys of the tables not moved yet.
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
        r'CodexAccountDao|UsageSampleDao)\b|'
        r'karmashala_environments/store|'
        // Seeding them in a store; a cost test may still name them to count
        // that the app issues no statement against them.
        r'\b(INTO|UPDATE)\s+(execution_environments|'
        r'agent_installations|ssh_hosts|ssh_known_hosts|claude_accounts|'
        r'codex_accounts|usage_samples)\b|'
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
