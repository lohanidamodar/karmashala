import 'package:karmashala/src/features/mcp/mcp_tool_dispatcher.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala/src/features/snippets/application/snippet_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import 'package:agent_cli/process.dart';

/// The snippet tools, called over the real MCP endpoint and checked against the
/// pane they were supposed to have typed into.
///
/// Driven through the server rather than by constructing the tools class, for
/// the reason `terminal_control_tools_test.dart` gives: a tool that answers
/// plausibly while being wired to nothing would pass a direct call.
///
/// The one invariant across all of it: **`snippet_insert` types and stops.**
/// `terminal_run` writes `['flutter test', '\r']` at this same seam; anything
/// here that writes a `\r` for a snippet the user did not mark is the bug.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_snippet_tools_');
    db = AppDatabase.memory();
    final data =
        await (FakeDataServer()
              ..environmentRows.upsert(localHostEnvironment(testTime)))
            .override();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(data: data, database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  TerminalSessionsController controller() =>
      container.read(terminalSessionsControllerProvider.notifier);

  Future<({bool isError, String text, Object? structured})> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final json =
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp/${json['mcpToken']}'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, Object?>{'name': name, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      final result =
          (jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, Object?>)['result']!
              as Map<String, Object?>;
      final content =
          (result['content']! as List<Object?>).first as Map<String, Object?>;
      return (
        isError: result['isError'] == true,
        text: content['text']! as String,
        structured: result['structuredContent'],
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Opens a pane and records what it would hand its process.
  ({String paneId, List<String> written}) pane([
    TerminalProfile profile = TerminalProfile.powerShell,
  ]) {
    controller().openTab(profile);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .focusedPaneId;
    final written = <String>[];
    controller().instanceFor(paneId)!.terminal.onOutput = written.add;
    return (paneId: paneId, written: written);
  }

  String save({
    String label = 'Run the tests',
    String command = 'flutter test',
    String? shellId,
    bool submit = false,
  }) => container
      .read(commandSnippetsProvider.notifier)
      .add(label: label, command: command, shellId: shellId, submit: submit)
      .id;

  group('snippets_list', () {
    test('reports every snippet, and which fit the pane in front', () async {
      pane();
      save();
      save(label: 'Tail the log', command: 'tail -f log', shellId: 'wsl');

      final result = await callTool('snippets_list');
      final structured = result.structured! as Map<String, Object?>;
      final snippets = (structured['snippets']! as List<Object?>)
          .cast<Map<String, Object?>>();

      expect(snippets, hasLength(2));
      expect(
        {for (final s in snippets) s['label']: s['fitsPane']},
        {'Run the tests': true, 'Tail the log': false},
        reason:
            'a WSL snippet is listed in a PowerShell pane with fitsPane=false '
            '— hiding it would look like it was never saved',
      );
      expect(
        (structured['pane']! as Map<String, Object?>)['shell'],
        'powerShell',
      );
    });

    test('answers with no pane at all rather than refusing', () async {
      save();

      final structured =
          (await callTool('snippets_list')).structured! as Map<String, Object?>;

      expect(structured['pane'], isNull);
      expect(
        ((structured['snippets']! as List<Object?>).first
            as Map<String, Object?>)['fitsPane'],
        isNull,
        reason: 'null is "no pane to compare against", not "does not fit"',
      );
    });
  });

  group('snippet_add', () {
    test('saves what the user will see in their own palette', () async {
      final result = await callTool('snippet_add', {
        'command': 'flutter test --exclude-tags=live-ssh',
        'label': 'Run the tests',
        'shell': 'powerShell',
      });

      expect(result.isError, isFalse);
      final saved = container.read(commandSnippetsProvider).single;
      expect(saved.label, 'Run the tests');
      expect(saved.shellId, 'powerShell');
      expect(
        saved.submit,
        isFalse,
        reason: 'an agent has to ask for a self-running snippet explicitly',
      );
    });

    test('flattens a multi-line command instead of storing a submit', () async {
      await callTool('snippet_add', {'command': 'git add -A\ngit commit'});

      expect(
        container.read(commandSnippetsProvider).single.command,
        'git add -A git commit',
      );
    });

    test('an unknown shell is refused, never dropped', () async {
      final result = await callTool('snippet_add', {
        'command': 'ls',
        'shell': 'fish',
      });

      expect(result.isError, isTrue);
      expect(result.text, contains('fish'));
      expect(
        container.read(commandSnippetsProvider),
        isEmpty,
        reason: 'a mis-tagged snippet is worse than no snippet',
      );
    });

    test('a blank command is refused', () async {
      expect(
        (await callTool('snippet_add', {'command': '  '})).isError,
        isTrue,
      );
    });
  });

  group('snippet_insert', () {
    test('types into the focused pane and does not press Enter', () async {
      final target = pane();
      final id = save();

      final result = await callTool('snippet_insert', {'id': id});
      final structured = result.structured! as Map<String, Object?>;

      expect(result.isError, isFalse);
      expect(target.written, ['flutter test']);
      expect(structured['submitted'], isFalse);
      expect(structured['paneId'], target.paneId);
      expect(structured['note'], contains('has NOT run'));
    });

    test('runs only what the user themselves marked as running', () async {
      final target = pane();
      final id = save(command: 'flutter clean', submit: true);

      final structured =
          (await callTool('snippet_insert', {'id': id})).structured!
              as Map<String, Object?>;

      expect(target.written, ['flutter clean', '\r']);
      expect(structured['submitted'], isTrue);
    });

    test('there is no argument that can make a snippet run', () async {
      final target = pane();
      final id = save();

      // Passed anyway, the way a caller that assumed a flag would. It is not in
      // the schema and it changes nothing: the decision belongs to whoever
      // saved the snippet.
      await callTool('snippet_insert', {'id': id, 'submit': true});

      expect(target.written, ['flutter test']);
    });

    test('a snippet for another shell is refused, not run anyway', () async {
      final target = pane();
      final id = save(command: 'tail -f log', shellId: 'wsl');

      final result = await callTool('snippet_insert', {'id': id});

      expect(result.isError, isTrue);
      expect(result.text, contains('WSL'));
      expect(target.written, isEmpty);
    });

    test('an agent pane is typed into but never submitted', () async {
      final opened = controller().openAgentTab(
        const AgentPaneLaunch(agentId: 'claude', executable: 'claude'),
      );
      final written = <String>[];
      controller().instanceFor(opened.paneId)!.terminal.onOutput = written.add;
      final id = save(submit: true);

      final structured =
          (await callTool('snippet_insert', {'id': id})).structured!
              as Map<String, Object?>;

      expect(written, ['flutter test']);
      expect(structured['submitted'], isFalse);
      expect(structured['note'], contains('takes a turn in a live session'));
    });

    test('an unknown snippet is an error, not a silent no-op', () async {
      pane();
      final result = await callTool('snippet_insert', {'id': 'ghost'});

      expect(result.isError, isTrue);
      expect(result.text, contains('ghost'));
    });

    test('no pane at all is an error that says what to do', () async {
      final id = save();
      final result = await callTool('snippet_insert', {'id': id});

      expect(result.isError, isTrue);
      expect(result.text, contains('terminal_open'));
    });
  });

  group('the catalogue', () {
    test('every snippet tool is served and annotated', () {
      final served = <String>{
        for (final schema in McpToolDispatcher.toolSchemas)
          schema['name']! as String,
      };

      expect(
        served.intersection({'snippets_list', 'snippet_add', 'snippet_insert'}),
        hasLength(3),
      );
      expect(kMcpToolAnnotations['snippets_list']!.readOnly, isTrue);
      expect(kMcpToolAnnotations['snippet_add']!.idempotent, isFalse);
      expect(
        kMcpToolAnnotations['snippet_insert']!.destructive,
        isTrue,
        reason:
            'the annotation describes the worst it does, and the worst is a '
            'snippet the user saved with submit=true — a client deciding '
            'whether to confirm cannot see which one this is',
      );
    });

    test('there is no way for an agent to delete somebody\'s library', () {
      expect(kMcpToolAnnotations.containsKey('snippet_delete'), isFalse);
    });
  });
}
