import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/window_tool_sets.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_snippets/store.dart' show CommandSnippetDao;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// Slice 5b: `open_session`, `snippet_insert` and `select_checkout` are the
/// server's; the window a person last used is only asked to show the result,
/// and with none connected each says so at once.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);
  final local = Platform.isWindows ? 'windowsNative' : 'localPosix';

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late ServerToolContext context;
  late ServerTerminals terminals;
  late OpenSessionToolSet open;
  late SnippetInsertToolSet snippets;
  late SelectCheckoutToolSet select;
  var ids = 0;

  setUp(() {
    ids = 0;
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['local', local, 'Here', '$t0'],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Cart',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'conv-1',
      ),
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    final data = DataService(database, clock: () => t0);
    context = ServerToolContext(
      database: database,
      data: data,
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    final rows = CheckoutRows(database);
    final launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: data.installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
    terminals = ServerTerminals(
      registry: registry,
      environments: () => data.environments,
      tell: (_) {},
      hostEnvironment: const {'SHELL': '/bin/sh'},
      installedShells: () => const ['/bin/sh'],
    );
    open = OpenSessionToolSet(context, launches: launches);
    snippets = SnippetInsertToolSet(context, terminals: terminals);
    select = SelectCheckoutToolSet(context);
  });

  tearDown(() async {
    context.close();
    await terminals.dispose();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  List<DataChange> window() {
    final told = <DataChange>[];
    context.data
        .open((batch) => told.addAll(batch.changes))
        .handle(const DataSubscribe());
    return told;
  }

  Future<Map<String, Object?>> call(
    dynamic tools,
    String tool,
    Map<String, dynamic> args,
  ) async =>
      (await (tools.call(tool, args, null) as Future<Object?>).timeout(
            const Duration(seconds: 5),
          ))
          as Map<String, Object?>;

  Matcher refusedWith(String words) => throwsA(
    isA<StateError>().having((e) => e.message, 'message', contains(words)),
  );

  group('open_session', () {
    test('a session not running is resumed here, then shown', () async {
      final told = window();
      final answer = await call(open, 'open_session', {'id': 's1'});
      expect(answer['reattached'], isFalse);
      expect(registry.find('karmashala_s1'), isNotNull);
      expect(pty.started.single.argv.join(' '), contains('--resume conv-1'));
      expect(told.whereType<OpenSessionTab>().single.sessionId, 's1');
      expect(answer['where'], contains('shown in a tab'));
    });

    test('a running session is only shown, nothing started', () async {
      await call(open, 'open_session', {'id': 's1'});
      final told = window();
      final answer = await call(open, 'open_session', {'id': 's1'});
      expect(answer['reattached'], isTrue);
      expect(pty.started, hasLength(1));
      expect(told.whereType<OpenSessionTab>(), hasLength(1));
      expect(told.whereType<OpenSessionTab>().single.reveal, TabReveal.front);
    });

    test('a session asks to open is shown behind the person\'s tab', () async {
      final told = window();
      await (open.call('open_session', {'id': 's1'}, 'caller')
              as Future<Object?>)
          .timeout(const Duration(seconds: 5));
      expect(
        told.whereType<OpenSessionTab>().single.reveal,
        TabReveal.background,
      );
    });

    test('with no window, the session still runs and the answer says so, '
        'at once', () async {
      final answer = await call(open, 'open_session', {'id': 's1'});
      expect(registry.find('karmashala_s1'), isNotNull);
      expect(answer['where'], contains('no Karmashala window is open'));
    });

    test('an imported session is opened by the window, or refused without '
        'one', () async {
      database.execute(
        'INSERT INTO imported_sessions (id, repository_id, source, '
        'external_id, environment_id, title, preview, file_path, store_home, '
        'is_subagent, updated_at, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          'imp1',
          'r1',
          AgentIds.claudeCode,
          'ext-9',
          'local',
          'Old chat',
          '',
          '/tmp/x.jsonl',
          '/tmp',
          0,
          '$t0',
          '$t0',
        ],
      );
      await expectLater(
        open.call('open_session', {'id': 'imp1'}, null),
        refusedWith('NOTHING WAS SHOWN'),
      );
      final told = window();
      await call(open, 'open_session', {'id': 'imp1'});
      expect(told.whereType<OpenImportedSession>().single.importedId, 'imp1');
      expect(pty.started, isEmpty);
    });

    test('an unknown id is refused', () async {
      await expectLater(
        open.call('open_session', {'id': 'nope'}, null),
        refusedWith('Session not found'),
      );
    });
  });

  group('snippet_insert', () {
    void saveSnippet({String? shell, bool submit = false}) =>
        CommandSnippetDao(database).insert(
          CommandSnippet(
            id: 'k1',
            label: 'test',
            command: 'make test',
            shellId: shell,
            submit: submit,
            createdAt: t0,
            updatedAt: t0,
          ),
        );

    test('an unknown snippet is refused', () async {
      window();
      await expectLater(
        snippets.call('snippet_insert', {'id': 'nope'}, null),
        refusedWith('No snippet with id nope'),
      );
    });

    test(
      'a snippet for another shell is refused for a server terminal',
      () async {
        terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
        saveSnippet(shell: 'commandPrompt');
        window();
        await expectLater(
          snippets.call('snippet_insert', {'id': 'k1', 'paneId': 'p1'}, null),
          refusedWith('is tagged for commandPrompt'),
        );
      },
    );

    test('an unknown pane is refused', () async {
      saveSnippet();
      window();
      await expectLater(
        snippets.call('snippet_insert', {'id': 'k1', 'paneId': 'gone'}, null),
        refusedWith('No terminal pane with id gone'),
      );
    });

    test(
      'the window is asked to type it into the pane, left at the prompt',
      () async {
        terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
        saveSnippet();
        final told = window();
        final answer = await call(snippets, 'snippet_insert', {
          'id': 'k1',
          'paneId': 'p1',
        });
        final intent = told.whereType<InsertSnippet>().single;
        expect(intent.snippetId, 'k1');
        expect(intent.paneId, 'p1');
        expect(answer['submitted'], isFalse);
        expect(answer['command'], 'make test');
      },
    );

    test('with no window, NOTHING WAS SHOWN, at once', () async {
      saveSnippet();
      await expectLater(
        snippets.call('snippet_insert', {'id': 'k1'}, null),
        refusedWith('NOTHING WAS SHOWN'),
      );
    });
  });

  group('select_checkout', () {
    test('the window is asked to point at the checkout', () async {
      final told = window();
      final answer = await call(select, 'select_checkout', {
        'repositoryId': 'r1',
      });
      expect(answer['selected'], isTrue);
      expect(told.whereType<SelectCheckout>().single.repositoryId, 'r1');
    });

    test('an unknown checkout is refused', () async {
      window();
      await expectLater(
        select.call('select_checkout', {'repositoryId': 'nope'}, null),
        refusedWith('No checkout with id nope'),
      );
    });

    test('with no window it is refused in words', () async {
      await expectLater(
        select.call('select_checkout', {'repositoryId': 'r1'}, null),
        refusedWith('NOTHING WAS SHOWN'),
      );
    });
  });
}
