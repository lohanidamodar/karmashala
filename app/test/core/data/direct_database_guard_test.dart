import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **The app is a client of the server's data** (docs/daemon-architecture.md,
/// "Slice 1 — data through the server").
///
/// Notes, todos, preferences and the workspace (contexts, projects, checkouts,
/// saved sections) go through the server's data API (`lib/src/core/data/`,
/// `WorkspaceData`); nothing under `lib/` opens their tables or the
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
    'environments and SSH hosts': [
      'src/features/environments/application/environment_providers.dart',
      'src/features/environments/data/execution_environment_dao.dart',
      'src/features/ssh/application/ssh_providers.dart',
      'src/features/ssh/data/known_host_dao.dart',
      'src/features/ssh/data/ssh_host_dao.dart',
    ],
    'agents, accounts and usage': [
      'src/features/agents/application/agent_providers.dart',
      'src/features/agents/application/claude_accounts_controller.dart',
      'src/features/agents/application/codex_accounts_controller.dart',
      'src/features/agents/application/usage_history.dart',
      'src/features/agents/data/agent_installation_dao.dart',
      'src/features/agents/data/claude_account_dao.dart',
      'src/features/agents/data/codex_account_dao.dart',
      'src/features/agents/data/usage_sample_dao.dart',
    ],
    'sessions and their records': [
      'src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart',
      'src/features/sessions/application/session_launcher_start.dart',
      'src/features/sessions/application/session_providers.dart',
      'src/features/sessions/data/session_event_dao.dart',
      'src/features/sessions/data/session_recap_dao.dart',
      'src/features/sessions/data/session_relay_dao.dart',
      'src/features/sessions/data/session_repository_dao.dart',
      'src/features/follow_ups/application/follow_up_providers.dart',
      'src/features/follow_ups/data/follow_up_dao.dart',
      'src/features/remote/application/remote_providers.dart',
    ],
    'imported sessions and the conversation index': [
      'src/features/cli_detection/application/cli_detection_providers.dart',
      'src/features/cli_detection/data/conversation_index_dao.dart',
      'src/features/cli_detection/data/imported_session_dao.dart',
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
    // Notes, todos, preferences and the workspace are read and written
    // through the fake server (test/support/fake_data_server.dart); their
    // rules are tested in packages/karmashala_notes, karmashala_projects,
    // karmashala_store and server/test/data. The one exception is the
    // transitional `workspace_mirror.dart`, which copies the fake's workspace
    // rows into a test's database for the sessions' foreign keys until
    // sessions move (1c).
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
        r'ProjectDao|RepositoryDao|SectionDao)\b|'
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
