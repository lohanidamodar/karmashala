import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import 'package:agent_cli/process.dart';

/// The terminal tools, called over the MCP endpoint and checked against the
/// controller they are supposed to have driven.
///
/// The invariant behind all of them: an agent's pane is the *app's* pane. Every
/// assertion here reads `TerminalSessionsController` afterwards, so a tool that
/// answered plausibly while opening nothing fails.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_term_tools_');
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
  TerminalSessionsState state() =>
      container.read(terminalSessionsControllerProvider);

  /// Gives a pane enough history that the detach policy keeps it.
  ///
  /// `shouldDetachOnClose` releases an un-instrumented shell with six or fewer
  /// non-blank lines, on the grounds that a bare banner is nothing anyone comes
  /// back for. A fake pane starts empty, so a test about detaching has to make
  /// the pane worth detaching first.
  void busyPane(String paneId) {
    final terminal = controller().instanceFor(paneId)!.terminal;
    for (var i = 0; i < 10; i++) {
      terminal.write('line $i\r\n');
    }
  }

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

  group('terminal_open', () {
    test('a tab appears in the layout, not somewhere private', () async {
      expect(state().tabs, isEmpty);

      final result = await callTool('terminal_open', {
        'workingDirectory': r'C:\work',
      });
      final structured = result.structured! as Map<String, Object?>;

      expect(state().tabs, hasLength(1));
      expect(state().tabs.single.id, structured['tabId']);
      expect(state().activeTabId, structured['tabId']);
      final instance = controller().instanceFor(
        structured['paneId']! as String,
      );
      expect(instance, isNotNull);
      expect(instance!.workingDirectory, r'C:\work');
    });

    test('an unknown profile is refused, never substituted', () async {
      final result = await callTool('terminal_open', {
        'profileId': 'fish-on-a-mainframe',
      });

      expect(result.isError, isTrue);
      expect(result.text, contains('No terminal profile'));
      // The important half: nothing was opened in some other shell.
      expect(state().tabs, isEmpty);
    });

    test('a named profile is the one that opens', () async {
      final result = await callTool('terminal_open', {
        'profileId': TerminalProfile.commandPromptId,
      });
      final structured = result.structured! as Map<String, Object?>;

      expect(
        controller().instanceFor(structured['paneId']! as String)!.profileId,
        TerminalProfile.commandPromptId,
      );
    });
  });

  group('terminal_run', () {
    test('the command is typed into that pane and submitted', () async {
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      final paneId = opened['paneId']! as String;
      final written = <String>[];
      controller().instanceFor(paneId)!.terminal.onOutput = written.add;

      final result = await callTool('terminal_run', {
        'paneId': paneId,
        'command': 'flutter test',
      });

      expect(result.isError, isFalse);
      expect(written, ['flutter test', '\r']);
    });

    test('an unknown pane is an error, not a silent no-op', () async {
      final result = await callTool('terminal_run', {
        'paneId': 'ghost',
        'command': 'ls',
      });
      expect(result.isError, isTrue);
      expect(result.text, contains('ghost'));
    });

    test('a blank command is refused', () async {
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      final result = await callTool('terminal_run', {
        'paneId': opened['paneId'],
        'command': '  ',
      });
      expect(result.isError, isTrue);
    });

    test('an un-integrated pane admits the exit code is unknown', () async {
      // These fakes have no shell integration, which is the honest half of the
      // waiting tool: it returns at once and says it cannot know how the
      // command ended, rather than reporting a zero nobody gave it.
      // `terminal_run_test.dart` covers the waiting half.
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      final result = await callTool('terminal_run', {
        'paneId': opened['paneId'],
        'command': 'sleep 60',
      });
      final structured = result.structured! as Map<String, Object?>;
      expect(structured['finished'], isFalse);
      expect(structured['exitCode'], isNull);
      expect(structured['exitCodeKnown'], isFalse);
      expect(structured['note'], contains('UNKNOWN'));
    });
  });

  group('terminal_output', () {
    test('reads what the pane shows', () async {
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      final paneId = opened['paneId']! as String;
      controller()
          .instanceFor(paneId)!
          .terminal
          .write('build succeeded\r\n42 tests passed\r\n');

      final result = await callTool('terminal_output', {'paneId': paneId});
      final lines =
          ((result.structured! as Map<String, Object?>)['lines']!
                  as List<Object?>)
              .join('\n');

      expect(lines, contains('build succeeded'));
      expect(lines, contains('42 tests passed'));
    });

    test('an unknown pane is an error', () async {
      final result = await callTool('terminal_output', {'paneId': 'ghost'});
      expect(result.isError, isTrue);
    });
  });

  group('terminal_list', () {
    test('names every tab, its panes and the profiles on offer', () async {
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;

      final structured =
          (await callTool('terminal_list')).structured! as Map<String, Object?>;
      final tabs = structured['tabs']! as List<Object?>;
      final tab = tabs.single as Map<String, Object?>;

      expect(tab['id'], opened['tabId']);
      expect(tab['active'], isTrue);
      final pane = (tab['panes']! as List<Object?>).single as Map;
      expect(pane['paneId'], opened['paneId']);
      expect(pane['live'], isTrue);
      // The profile list is what terminal_open's profileId comes from, so an
      // agent can pick a shell without being told the ids out of band.
      expect(structured['profiles'], isNotEmpty);
    });

    test('a detached pane is listed, not lost', () async {
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      busyPane(opened['paneId']! as String);
      await callTool('terminal_close', {'tabId': opened['tabId']});

      final structured =
          (await callTool('terminal_list')).structured! as Map<String, Object?>;

      expect(structured['tabs'], isEmpty);
      final detached = (structured['detached']! as List<Object?>).single as Map;
      expect(detached['paneId'], opened['paneId']);
      expect(detached['live'], isTrue);
    });
  });

  group('terminal_close', () {
    test('a pane with work in it is detached, not ended', () async {
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      final paneId = opened['paneId']! as String;
      busyPane(paneId);

      final result = await callTool('terminal_close', {
        'tabId': opened['tabId'],
      });

      expect(state().tabs, isEmpty);
      expect(state().detached.single.paneId, paneId);
      expect(
        controller().instanceFor(paneId),
        isNotNull,
        reason: 'detaching keeps the instance; only ending releases it',
      );
      expect(
        ((result.structured! as Map)['panes']! as List).single,
        containsPair('outcome', startsWith('detached')),
      );
    });

    test('an idle shell is ended, and the result says so', () async {
      // The app's own policy: a pane that has printed nothing beyond its
      // banner has nothing to come back for. The tool must report what
      // happened rather than repeat what it hoped would happen.
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      final paneId = opened['paneId']! as String;

      final result = await callTool('terminal_close', {
        'tabId': opened['tabId'],
      });

      expect(state().detached, isEmpty);
      expect(controller().instanceFor(paneId), isNull);
      expect(
        ((result.structured! as Map)['panes']! as List).single,
        containsPair('outcome', 'ended'),
      );
    });

    test('kill ends a pane the policy would have kept', () async {
      final opened =
          (await callTool('terminal_open')).structured! as Map<String, Object?>;
      final paneId = opened['paneId']! as String;
      busyPane(paneId);

      final result = await callTool('terminal_close', {
        'tabId': opened['tabId'],
        'kill': true,
      });

      expect(state().tabs, isEmpty);
      expect(state().detached, isEmpty);
      expect(controller().instanceFor(paneId), isNull);
      expect(
        ((result.structured! as Map)['panes']! as List).single,
        containsPair('outcome', 'ended'),
      );
    });

    test('an unknown tab is an error', () async {
      final result = await callTool('terminal_close', {'tabId': 'ghost'});
      expect(result.isError, isTrue);
      expect(result.text, contains('ghost'));
    });
  });
}
