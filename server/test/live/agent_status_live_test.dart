@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:test/test.dart';

import 'companion_live_harness.dart';
import 'local_host_harness.dart';

/// What a hosted agent is doing, kept by a real `karmashala_host serve` across
/// a stretch with no app connected — found live on 2026-09-25: an agent at its
/// folder-trust question with the app open; the app quits; `session_answer`
/// approves it through the daemon; the agent replies and stops, firing its
/// hooks at the daemon; the app, reopened 30 s later, read `unknown` with no
/// evidence. This is the daemon's half, and it holds: the reopened link's
/// snapshot says idle, by the Stop hook. (The app's half — the registry
/// holding that snapshot back behind its first cycle's disk work — is in
/// `test/features/sessions/host_lifecycle_test.dart`.)
///
/// Everything here is the shipped path: the built host, its hook
/// server posted to by `curl` from inside the agent's PTY with the pane's
/// `KARMASHALA_SESSION_ID`, its MCP endpoint, and the app's lifecycle client.
/// The agent is a stand-in that draws Claude Code's real trust screen, and on
/// Enter its real idle screen, then fires the hooks Claude Code fires.
void main() {
  test(
    'a status that moved while no app was connected is the reopened app\'s',
    () async {
      final home = temporaryHome('karmashala-status-live');
      final dataDir = Directory('${home.path}/data');
      seedStore(dataDir);
      final host = await LocalHost.start(home);
      addTearDown(host.kill);
      final hooks = HookEndpoint.read(host.paths.hookEndpointPath);
      expect(hooks, isNotNull, reason: host.greeting);
      final mcpPort = int.parse(
        RegExp(
          r'agent tools on port (\d+)',
        ).firstMatch(host.greeting)!.group(1)!,
      );

      // Claude Code's own screens, cut before each capture's teardown.
      File screen(String name, String fixture) {
        final captured = File(
          '../app/test/features/agents/fixtures/$fixture.raw',
        ).readAsStringSync();
        final teardown = captured.indexOf('Session terminated');
        return File('${home.path}/$name.raw')..writeAsStringSync(
          teardown < 0 ? captured : captured.substring(0, teardown),
        );
      }

      final trust = screen('trust', 'claude-code-trust-prompt');
      final idle = screen('idle', 'claude-code-tui');
      // The same question with the highlight one row down, as Claude Code
      // redraws it on the Down key the menu answerer presses.
      const noRow =
          '\x1b[2G\x1b[38;5;153m\u276f\x1b[4GNo,\x1b[8Gexit\x1b[39m\r\r\n'
          '\x1b[4GYes,\x1b[9GI\x1b[11Gtrust\x1b[17Gthis\x1b[22Gfolder\r\r\n';
      const yesRow =
          '\x1b[4GNo,\x1b[8Gexit\r\r\n'
          '\x1b[2G\x1b[38;5;153m\u276f\x1b[4GYes,\x1b[9GI\x1b[11Gtrust'
          '\x1b[17Gthis\x1b[22Gfolder\x1b[39m\r\r\n';
      final question = trust.readAsStringSync();
      expect(question, contains(noRow), reason: 'the capture moved');
      final trustYes = File('${home.path}/trust-yes.raw')
        ..writeAsStringSync(question.replaceFirst(noRow, yesRow));
      // Raw, as Claude Code's TUI is: one key at a time, nothing echoed. A
      // Down redraws the question, Enter confirms it; then Claude replies,
      // stops, and fires its hooks as the installed script sends them —
      // bearer token, the pane's session in the header, one POST per event.
      final agent = File('${home.path}/fake-claude.sh')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'stty raw -echo\n'
          "printf '\\033[2J\\033[H'\n"
          'cat "\$1"\n'
          'while :; do\n'
          '  key=\$(dd bs=1 count=1 2>/dev/null)\n'
          "  case \"\$key\" in\n"
          "    B) printf '\\033[2J\\033[H'; cat \"\$6\" ;;\n"
          "    \"\$(printf '\\r')\") break ;;\n"
          '  esac\n'
          'done\n'
          "printf '\\033[2J\\033[H'\n"
          'cat "\$2"\n'
          'for event in SessionStart UserPromptSubmit Stop; do\n'
          '  curl -s -o /dev/null -m 5 -X POST \\\n'
          '    -H "Authorization: Bearer \$4" \\\n'
          '    -H "$kHookSessionHeader: \$KARMASHALA_SESSION_ID" \\\n'
          '    --data-binary "{\\"session_id\\":\\"conv-live\\",'
          '\\"hook_event_name\\":\\"\$event\\",\\"stop_hook_active\\":false}" '
          '\\\n'
          '    "http://127.0.0.1:\$3/agent-hook?agent=${AgentIds.claudeCode}'
          '&event=\$event"\n'
          'done\n'
          // Off screen, so the grid reads the idle footer, not this.
          'echo "HOOKS-SENT" > "\$5"\n'
          'exec sleep 600\n',
        );
      final sent = File('${home.path}/hooks-sent');

      // The app is open and launches the agent in the row's host session.
      final app = await HostLifecycleWatch.connect(host.socketPath);
      expect(app, isNotNull);
      // Its tools, which the daemon keeps serving once the app is gone.
      app!.offerMcpTools(const [
        {
          'name': 'session_answer',
          'description': 'Answers a session\'s open prompt.',
          'inputSchema': {'type': 'object'},
        },
      ]);
      final firstStatuses = StreamIterator(app.agentStatuses);
      final pane = await LocalHostClient.connect(host.socketPath, 'app-pane');
      await pane.expect<WelcomeMessage>();
      pane.send(
        OpenMessage(
          requestId: pane.nextId(),
          sessionId: hostSessionIdOf(seededAgentSessionId),
          argv: [
            '/bin/sh',
            agent.path,
            trust.path,
            idle.path,
            '${hooks!.port}',
            hooks.token,
            sent.path,
            trustYes.path,
          ],
          workingDirectory: home.path,
          environment: const {
            'TERM': 'xterm-256color',
            'KARMASHALA_SESSION_ID': seededAgentSessionId,
          },
          columns: 120,
          rows: 30,
        ),
      );
      await pane.expect<AttachedMessage>();

      // It sits at the folder-trust question, and the app is told so.
      HostedAgentStatus? asking;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (asking == null && DateTime.now().isBefore(deadline)) {
        final more = await firstStatuses.moveNext().timeout(
          const Duration(seconds: 20),
          onTimeout: () => false,
        );
        if (!more) break;
        final frame = firstStatuses.current;
        if (frame.sessionId != seededAgentSessionId) continue;
        final status = HostedAgentStatus.fromJson(frame.status);
        if (status?.report.hasOpenPrompt ?? false) asking = status;
      }
      expect(asking, isNotNull, reason: host.output);
      expect(asking!.report.source, AgentStatusSource.terminalGrid);

      // The app quits: its pane and its lifecycle link go.
      await pane.close();
      await firstStatuses.cancel();
      await app.close();

      // An agent approves it through the daemon's MCP, the app closed.
      final credentials = McpCredentials.read(host.paths.mcpCredentialsPath);
      expect(credentials, isNotNull, reason: host.output);
      final reply = await _callTool(
        mcpPort,
        // Another session is the caller; the seeded plain row is not over.
        credentials!.callerKey.tokenFor(seededSessionId),
        'session_answer',
        {'sessionId': seededAgentSessionId, 'decision': 'approve'},
      );
      expect(reply['result'], isNotNull, reason: '$reply');
      final result = reply['result']! as Map<String, Object?>;
      expect(result['isError'], isNot(true), reason: '$reply');
      final text =
          ((result['content']! as List).single as Map<String, Object?>)['text']
              as String;
      expect(text, contains('Yes, I trust this folder'));

      // Claude carries on, replies, stops, and fires its hooks.
      final hooksDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (!sent.existsSync() && DateTime.now().isBefore(hooksDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(sent.existsSync(), isTrue, reason: host.output);
      // A few of the daemon's own screen reads, with nobody watching.
      await Future<void>.delayed(const Duration(seconds: 3));

      // The app opens again, the same host still running.
      final back = await HostLifecycleWatch.connect(host.socketPath);
      addTearDown(() => back?.close());
      final kept = [
        for (final json in back!.statusSnapshot)
          ?HostedAgentStatus.fromJson(json),
      ].where((s) => s.sessionId == seededAgentSessionId).toList();
      expect(kept, hasLength(1), reason: host.output);
      final latest = kept.single.report;
      expect(
        latest.status,
        AgentActivityStatus.idle,
        reason: '${kept.single.toJson()}\n${host.output}',
      );
      expect(latest.source, AgentStatusSource.hook);
      expect(latest.detail, 'Stop');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// One MCP `tools/call` on the daemon's endpoint, as the calling session.
Future<Map<String, Object?>> _callTool(
  int port,
  String token,
  String tool,
  Map<String, Object?> arguments,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/mcp/$token'),
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': tool, 'arguments': arguments},
      }),
    );
    final response = await request.close().timeout(const Duration(seconds: 30));
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}
