@Tags(['live-acp'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart'
    show StopReason, ToolCallStatus, ToolCallUpdate, ToolKind;
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/acp/claude/claude_stream_json_bridge.dart'
    show kClaudeStreamJsonVerifiedWith;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../acp/acp_fixture.dart' show RecordingHost;

/// Claude chat over the person's own `claude`, through the stream-json
/// bridge, started exactly as the launcher starts it: on this machine, and
/// in a WSL distribution when KARMASHALA_LIVE_CLAUDE_WSL names one. Opt-in:
/// it spends model turns (on Haiku) and needs `claude` installed and logged
/// in, so it skips unless KARMASHALA_LIVE_ACP=1. A small MCP endpoint of the
/// test's own stands in for Karmashala's, so a tool reaching Claude is
/// measured too. What no fake can measure: that the binary's real stream
/// meets the bridge as the fake says it does.
void main() {
  final live = Platform.environment['KARMASHALA_LIVE_ACP'] == '1';
  final local = _localClaude();
  test(
    'on this machine: a read-only turn, an MCP tool, a denied write, an '
    'interrupt, and the conversation resumed in a new process',
    () async => _exercise(await _Place.local(local!)),
    skip: !live
        ? 'set KARMASHALA_LIVE_ACP=1 to run the real claude'
        : local == null
        ? 'no claude binary found'
        : null,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  final distribution = Platform.environment['KARMASHALA_LIVE_CLAUDE_WSL'];
  test(
    'in WSL: the same',
    () async => _exercise(await _Place.wsl(distribution!)),
    skip: !live
        ? 'set KARMASHALA_LIVE_ACP=1 to run the real claude'
        : distribution == null || !Platform.isWindows
        ? 'set KARMASHALA_LIVE_CLAUDE_WSL=<distribution> to run it in WSL'
        : null,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<void> _exercise(_Place place) async {
  final log = StringBuffer();
  void note(String line) {
    log.writeln('[${DateTime.now().toIso8601String()}] $line');
    stdout.writeln('claude-live ${place.name}: $line');
  }

  note(
    'claude --version: ${place.version} (bridge verified with '
    '$kClaudeStreamJsonVerifiedWith)',
  );
  await place.write('hello.txt', 'banana bread\n');
  final mcp = await _SecretMcp.start(place.mcpHost);
  note('MCP endpoint ${mcp.url}');
  final database = AppDatabase.memory();
  database.execute('PRAGMA foreign_keys = OFF;');
  final messages = SessionMessageDao(database);
  final host = RecordingHost();
  final runtimes = AcpRuntimes(
    messages: messages,
    host: host,
    runnerFor: (env) => const CommandRunnerFactory().forEnvironment(env!),
  );
  final spec = claudeAcpDescriptor.acp!;
  AcpSessionRuntime start(String sessionId, {String? resume}) => runtimes.start(
    AcpSessionStart(
      sessionId: sessionId,
      hostSessionId: 'karmashala_$sessionId',
      agentId: AgentIds.claudeAcp,
      agentName: 'Claude',
      spec: spec,
      executable: place.claude,
      arguments: spec.argumentsFor(linux: place.linux),
      directory: EnvironmentPath(
        environmentId: place.environment.id,
        path: place.directory,
      ),
      environment: place.environment,
      // Run from inside Claude Code, the test must not look like it.
      removed: const {'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT'},
      mcpUrl: mcp.url,
      risk: PermissionRisk.ask,
      resumeSessionId: resume,
    ),
  );
  List<SessionMessage> rows(String sessionId) => messages.listAfter(sessionId);
  String said(String sessionId) => rows(sessionId)
      .where((r) => r.role == SessionMessageRole.agent)
      .map((r) => r.text)
      .join(' ');
  String dump(String sessionId) {
    final buffer = StringBuffer(log.toString());
    for (final row in rows(sessionId)) {
      buffer.writeln(
        '  ${row.ordinal} ${row.role.name} text=${jsonEncode(row.text)} '
        'tool=${row.toolJson ?? '-'}',
      );
    }
    buffer.writeln('statuses: ${host.statuses.map((s) => s.status.name)}');
    return buffer.toString();
  }

  List<ToolCallUpdate> tools(String sessionId) => [
    for (final row in rows(sessionId))
      if (row.toolJson != null)
        ToolCallUpdate.fromJson(
          jsonDecode(row.toolJson!) as Map<String, Object?>,
          isNew: true,
        ),
  ];

  /// Waits out the open turn, answering every permission it asks with
  /// [approve]; how many were asked.
  Future<int> settle(AcpSessionRuntime runtime, {required bool approve}) async {
    var settled = false;
    unawaited(runtime.awaitTurn().whenComplete(() => settled = true));
    var asked = 0;
    while (!settled) {
      if (runtime.hasOpenPermission) {
        final answer = await runtime.answerPermission(approve: approve);
        asked++;
        note('answered "${answer.toolTitle}" with "${answer.answered}"');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return asked;
  }

  const s1 = 'live-claude-1';
  final first = start(s1);
  AcpSessionRuntime? second;
  try {
    final clock = Stopwatch()..start();
    final outcome = await first.start();
    note(
      'started in ${clock.elapsedMilliseconds} ms: session '
      '${outcome.agentSessionId}, notices ${outcome.notices}',
    );
    expect(outcome.resumed, isFalse);
    expect(outcome.notices, isEmpty, reason: 'an MCP endpoint was handed');
    expect(first.modes!.currentModeId, 'default');
    final models = first.configOptions!.options.single;
    expect(models.choices.map((c) => c.value), contains('haiku'));
    await first.setConfigOption('model', 'haiku');

    // A read-only turn.
    clock.reset();
    await first.send('Read hello.txt and reply with only its first word.');
    expect(await first.awaitTurn(), StopReason.endTurn, reason: dump(s1));
    note('turn 1 in ${clock.elapsedMilliseconds} ms');
    final reads = tools(s1).where((t) => t.kind == ToolKind.read);
    expect(reads, isNotEmpty, reason: dump(s1));
    expect(reads.first.status, ToolCallStatus.completed);
    expect(said(s1).toLowerCase(), contains('banana'), reason: dump(s1));
    final usage = host.usage.last;
    note(
      'usage: ${usage.contextUsed}/${usage.contextSize}, '
      '${usage.costAmount} ${usage.costCurrency}',
    );
    expect(usage.contextSize, greaterThan(0));
    expect(usage.costAmount, greaterThan(0));

    // A tool of the MCP server the session was handed.
    await first.send(
      'Call the secret_word tool of the karmashala MCP server (search for '
      'it with your tool search if it is deferred) and reply with only the '
      'word it returns.',
    );
    await settle(first, approve: true);
    final mcpCalls = tools(
      s1,
    ).where((t) => (t.title ?? '').contains('secret_word'));
    note(
      'MCP: ${mcp.calls} tools/call, rows ${mcpCalls.map((t) => '${t.title} '
          '${t.status?.raw}').toList()}',
    );
    expect(mcp.calls, greaterThanOrEqualTo(1), reason: dump(s1));
    expect(said(s1).toLowerCase(), contains('pineapple'), reason: dump(s1));

    // A question, answered with its first choice.
    await first.send(
      'Use the AskUserQuestion tool exactly once to ask me which fruit I '
      'prefer, with two options in this order: Apple, then Pear (single '
      'choice). Then reply with only my answer.',
    );
    final questions = await settle(first, approve: true);
    expect(questions, 1, reason: dump(s1));
    expect(said(s1).toLowerCase(), contains('apple'), reason: dump(s1));

    // A write, denied.
    await first.send(
      'Use your Write tool (not a shell) to create out.txt containing x. If '
      'it is refused, reply with the single word: refused',
    );
    final asked = await settle(first, approve: false);
    expect(asked, greaterThanOrEqualTo(1), reason: dump(s1));
    expect(await place.exists('out.txt'), isFalse);
    expect(
      tools(s1).where((t) => t.kind == ToolKind.edit).last.status,
      ToolCallStatus.failed,
    );

    // An interrupt mid-turn.
    await first.send(
      'Without tools, count from one to three hundred in words, one per line.',
    );
    final counting = Stopwatch()..start();
    while (!rows(s1).any((r) => r.text.contains('ten')) &&
        counting.elapsed < const Duration(seconds: 60)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    first.cancel();
    expect(await first.awaitTurn(), StopReason.cancelled, reason: dump(s1));
    note('interrupted after ${counting.elapsedMilliseconds} ms');
    note('stopped: ${await first.stop()}');

    // The conversation, resumed by id in a process of its own.
    const s2 = 'live-claude-2';
    second = start(s2, resume: outcome.agentSessionId);
    final resumed = await second.start();
    note('resumed: ${resumed.resumed}');
    expect(resumed.resumed, isTrue);
    await second.setConfigOption('model', 'haiku');
    await second.send(
      'Without tools: what was the first word of hello.txt, as you read it '
      'earlier in this conversation? Reply with the word only.',
    );
    expect(await second.awaitTurn(), StopReason.endTurn, reason: dump(s2));
    expect(said(s2).toLowerCase(), contains('banana'), reason: dump(s2));
    await second.stop();
  } finally {
    if (!first.lifecycle.hasEnded) await first.stop();
    if (second != null && !second.lifecycle.hasEnded) await second.stop();
    await mcp.close();
    database.close();
    await place.cleanUp();
    stdout.write(log);
  }
}

/// Where a run happens: the machine, its folder, and its `claude`.
final class _Place {
  _Place._({
    required this.name,
    required this.environment,
    required this.claude,
    required this.directory,
    required this.linux,
    required this.mcpHost,
    required this.version,
    required this.run,
  });

  final String name;
  final ExecutionEnvironment environment;
  final String claude;
  final String directory;
  final bool linux;

  /// The address a server here listens on and `claude` there dials.
  final String mcpHost;
  final String version;

  /// Runs a shell line where `claude` runs (local: none).
  final String Function(String script)? run;

  static Future<_Place> local(String claude) async {
    final temp = Directory.systemTemp.createTempSync('claude_live');
    return _Place._(
      name: 'local',
      environment: ExecutionEnvironment(
        id: 'windows',
        kind: Platform.isWindows
            ? EnvironmentKind.windowsNative
            : EnvironmentKind.localPosix,
        name: 'local',
        createdAt: DateTime.now().toUtc(),
      ),
      claude: claude,
      directory: temp.path,
      linux: Platform.isLinux,
      mcpHost: '127.0.0.1',
      version: '${Process.runSync(claude, ['--version']).stdout}'.trim(),
      run: null,
    );
  }

  static Future<_Place> wsl(String distribution) async {
    String run(String script) {
      final result = Process.runSync('wsl.exe', [
        '-d',
        distribution,
        '--',
        'bash',
        '-lc',
        script,
      ]);
      return '${result.stdout}'.trim();
    }

    final claude = run('command -v claude');
    // Without mirrored networking WSL reaches the Windows host at its
    // default gateway, not at 127.0.0.1.
    final gateway = run('ip route show default | cut -d" " -f3');
    return _Place._(
      name: 'wsl:$distribution',
      environment: ExecutionEnvironment(
        id: 'wsl:$distribution',
        kind: EnvironmentKind.wsl,
        name: distribution,
        wslDistribution: distribution,
        createdAt: DateTime.now().toUtc(),
      ),
      claude: claude,
      directory: run('mktemp -d'),
      linux: true,
      mcpHost: gateway,
      version: run('claude --version'),
      run: run,
    );
  }

  Future<void> write(String name, String content) async {
    final run = this.run;
    if (run == null) {
      File(
        '$directory${Platform.pathSeparator}$name',
      ).writeAsStringSync(content);
    } else {
      run("printf '%s' '${content.replaceAll("'", '')}' > '$directory/$name'");
    }
  }

  Future<bool> exists(String name) async {
    final run = this.run;
    if (run == null) {
      return File('$directory${Platform.pathSeparator}$name').existsSync();
    }
    return run("test -e '$directory/$name' && echo yes") == 'yes';
  }

  Future<void> cleanUp() async {
    final run = this.run;
    if (run != null) {
      run("rm -rf '$directory'");
      return;
    }
    try {
      Directory(directory).deleteSync(recursive: true);
    } on FileSystemException {
      // A process may still hold it for a moment on Windows.
    }
  }
}

/// A Streamable HTTP MCP server with one tool, `secret_word`, answering
/// "pineapple": enough of the protocol for Claude to list and call it.
final class _SecretMcp {
  _SecretMcp._(this._server, this.url);

  final HttpServer _server;
  final String url;
  var calls = 0;

  static Future<_SecretMcp> start(String host) async {
    final server = await HttpServer.bind(
      host == '127.0.0.1'
          ? InternetAddress.loopbackIPv4
          : InternetAddress.anyIPv4,
      0,
    );
    final mcp = _SecretMcp._(server, 'http://$host:${server.port}/mcp');
    server.listen(mcp._serve);
    return mcp;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'POST') {
      response.statusCode = request.method == 'DELETE'
          ? HttpStatus.ok
          : HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final body = jsonDecode(await utf8.decodeStream(request));
    final messages = body is List ? body : [body];
    final answers = [
      for (final message in messages.cast<Map<String, Object?>>())
        if (message['id'] != null) _answer(message),
    ];
    if (answers.isEmpty) {
      response.statusCode = HttpStatus.accepted;
      await response.close();
      return;
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body is List ? answers : answers.single));
    await response.close();
  }

  Map<String, Object?> _answer(Map<String, Object?> message) {
    final id = message['id'];
    Map<String, Object?> result(Object result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    switch (message['method']) {
      case 'initialize':
        final params = message['params'] as Map<String, Object?>?;
        return result({
          'protocolVersion': params?['protocolVersion'] ?? '2025-06-18',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'karmashala-live-test', 'version': '1'},
        });
      case 'tools/list':
        return result({
          'tools': [
            {
              'name': 'secret_word',
              'description': 'Returns the secret word.',
              'inputSchema': {
                'type': 'object',
                'properties': <String, Object?>{},
              },
            },
          ],
        });
      case 'tools/call':
        calls++;
        return result({
          'content': [
            {'type': 'text', 'text': 'pineapple'},
          ],
        });
      case 'ping':
        return result(<String, Object?>{});
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32601, 'message': 'no ${message['method']}'},
    };
  }

  Future<void> close() => _server.close(force: true);
}

String? _localClaude() {
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null) return null;
  final installed = File(
    Platform.isWindows
        ? '$home\\.local\\bin\\claude.exe'
        : '$home/.local/bin/claude',
  );
  return installed.existsSync() ? installed.path : null;
}
