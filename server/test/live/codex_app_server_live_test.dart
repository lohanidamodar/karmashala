@Tags(['live-acp'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart'
    show StopReason, ToolCallUpdate;
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../acp/acp_fixture.dart' show RecordingHost;

/// Codex's chat over the real `codex app-server` on this machine, through
/// the codexAppServer bridge, started as the launcher starts it: a
/// read-only turn in a temp folder, then the thread resumed by a second
/// runtime. Opt-in: it spends model turns and needs Codex logged in, so it
/// skips unless KARMASHALA_LIVE_ACP=1 and `codex` is found (or named by
/// KARMASHALA_CODEX).
void main() {
  final codex = _codex();
  test(
    'a read-only turn reads a file, then the thread resumes in a new process',
    () => _exercise(codex.path!),
    skip: codex.skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

({String? path, String? skip}) _codex() {
  if (Platform.environment['KARMASHALA_LIVE_ACP'] != '1') {
    return (path: null, skip: 'set KARMASHALA_LIVE_ACP=1 to run real Codex');
  }
  final named = Platform.environment['KARMASHALA_CODEX'];
  if (named != null && named.isNotEmpty) return (path: named, skip: null);
  final found = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'codex',
  ]);
  final first = '${found.stdout}'.split(RegExp(r'\r?\n')).first.trim();
  if (found.exitCode != 0 || first.isEmpty) {
    return (path: null, skip: 'no codex on PATH; set KARMASHALA_CODEX');
  }
  return (path: first, skip: null);
}

Future<void> _exercise(String codex) async {
  final log = StringBuffer();
  void note(String line) {
    log.writeln(line);
    stdout.writeln('codex-live: $line');
  }

  final environment = ExecutionEnvironment(
    id: 'local',
    kind: Platform.isWindows
        ? EnvironmentKind.windowsNative
        : EnvironmentKind.localPosix,
    name: 'This machine',
    createdAt: DateTime.now().toUtc(),
  );
  final temp = Directory.systemTemp.createTempSync('codex_live');
  File('${temp.path}/hello.txt').writeAsStringSync('karmashala live probe\n');
  final database = AppDatabase.memory();
  database.execute('PRAGMA foreign_keys = OFF;');
  final messages = SessionMessageDao(database);
  final host = RecordingHost();
  final runtimes = AcpRuntimes(
    messages: messages,
    usage: SessionUsageDao(database),
    host: host,
    runnerFor: (env) => const CommandRunnerFactory().forEnvironment(env!),
  );
  final spec = codexAcpDescriptor.acp!;
  AcpSessionRuntime open(String sessionId, {String? resume}) => runtimes.start(
    AcpSessionStart(
      sessionId: sessionId,
      hostSessionId: 'karmashala_$sessionId',
      agentId: AgentIds.codexAcp,
      agentName: 'Codex',
      spec: spec,
      executable: codex,
      arguments: spec.arguments,
      directory: EnvironmentPath(
        environmentId: environment.id,
        path: temp.path,
      ),
      environment: environment,
      variables: {'KARMASHALA_SESSION_ID': sessionId},
      risk: PermissionRisk.readOnly,
      resumeSessionId: resume,
    ),
  );

  String dump(String sessionId) {
    final buffer = StringBuffer(log.toString());
    for (final row in messages.listAfter(sessionId)) {
      buffer.writeln(
        '  ${row.role.name} text=${jsonEncode(row.text)} '
        'thinking=${row.thinking?.length ?? '-'} tool=${row.toolJson ?? '-'}',
      );
    }
    buffer.writeln(
      'statuses: ${host.statuses.map((s) => s.status.name).join(' > ')}',
    );
    return buffer.toString();
  }

  try {
    final first = open('live-codex-1');
    final outcome = await first.start();
    note(
      'started: thread ${outcome.agentSessionId}, notices ${outcome.notices}',
    );
    expect(outcome.resumed, isFalse);
    note(
      'modes: ${first.modes?.currentModeId} of '
      '${first.modes?.availableModes.map((m) => m.id).toList()}',
    );
    expect(first.modes?.currentModeId, 'read-only');
    final options = first.configOptions!.options;
    for (final option in options) {
      note(
        'option ${option.id} = ${option.currentValue} of '
        '${option.choices.map((c) => c.value).toList()}',
      );
    }
    expect(options.map((o) => o.id), contains('model'));

    await first.send(
      'Read hello.txt with a shell command, then reply with its contents '
      'and nothing else. Do not change any file.',
    );
    final reason = await first.awaitTurn();
    note('turn ended ${reason?.raw}');
    expect(reason, StopReason.endTurn, reason: dump('live-codex-1'));
    final rows = messages.listAfter('live-codex-1');
    final tools = [
      for (final row in rows)
        if (row.toolJson != null)
          ToolCallUpdate.fromJson(
            jsonDecode(row.toolJson!) as Map<String, Object?>,
            isNew: true,
          ),
    ];
    for (final tool in tools) {
      note(
        'tool "${tool.title}" kind=${tool.kind?.raw} '
        'status=${tool.status?.raw} input=${jsonEncode(tool.rawInput)} '
        'locations=${tool.locations?.map((l) => l.path).toList()}',
      );
    }
    expect(tools, isNotEmpty, reason: dump('live-codex-1'));
    expect(tools.first.rawInput, isA<Map<String, Object?>>());
    final reply = rows
        .where((r) => r.role == SessionMessageRole.agent)
        .map((r) => r.text)
        .join(' ');
    note('reply: ${jsonEncode(reply)}');
    expect(reply, contains('karmashala live probe'));
    note(
      'usage: ${host.usage.map((u) => '${u.contextUsed}/${u.contextSize}')}',
    );
    expect(host.usage, isNotEmpty);
    expect(temp.listSync().map((e) => e.uri.pathSegments.last), [
      'hello.txt',
    ], reason: 'a read-only turn changes nothing');
    await first.stop();

    final second = open('live-codex-2', resume: outcome.agentSessionId);
    final resumed = await second.start();
    note('resumed=${resumed.resumed}, notices ${resumed.notices}');
    expect(resumed.resumed, isTrue, reason: dump('live-codex-2'));
    expect(resumed.agentSessionId, outcome.agentSessionId);
    await second.send(
      'Which file did you read in this conversation? Reply with its name only.',
    );
    expect(await second.awaitTurn(), StopReason.endTurn);
    final recalled = messages
        .listAfter('live-codex-2')
        .where((r) => r.role == SessionMessageRole.agent)
        .map((r) => r.text)
        .join(' ');
    note('recalled: ${jsonEncode(recalled)}');
    expect(recalled, contains('hello.txt'));
    await second.stop();
  } finally {
    database.close();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Codex's sandbox helper may still hold the folder for a moment.
    }
  }
}
