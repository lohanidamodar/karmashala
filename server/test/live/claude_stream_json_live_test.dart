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

/// Claude chat over the person's own `claude` on this machine, through the
/// stream-json bridge, started exactly as the launcher starts it. Opt-in: it
/// spends model turns (on Haiku) and needs `claude` installed and logged in,
/// so it skips unless KARMASHALA_LIVE_ACP=1. What no fake can measure: that
/// the binary's real stream meets the bridge as the fake says it does.
void main() {
  final claude = _claudeBinary();
  final skip = Platform.environment['KARMASHALA_LIVE_ACP'] != '1'
      ? 'set KARMASHALA_LIVE_ACP=1 to run the real claude'
      : claude == null
      ? 'no claude binary found'
      : null;

  test(
    'a read-only turn, a denied write, an interrupt, and the conversation '
    'resumed by id in a new process',
    () => _exercise(claude!),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<void> _exercise(String claude) async {
  final log = StringBuffer();
  void note(String line) {
    log.writeln('[${DateTime.now().toIso8601String()}] $line');
    stdout.writeln('claude-live: $line');
  }

  final version = Process.runSync(claude, ['--version']).stdout;
  note(
    'claude --version: ${'$version'.trim()} (verified with '
    '$kClaudeStreamJsonVerifiedWith)',
  );
  final temp = Directory.systemTemp.createTempSync('claude_live');
  File(
    '${temp.path}${Platform.pathSeparator}hello.txt',
  ).writeAsStringSync('banana bread\n');
  final environment = ExecutionEnvironment(
    id: 'windows',
    kind: Platform.isWindows
        ? EnvironmentKind.windowsNative
        : EnvironmentKind.localPosix,
    name: 'local',
    createdAt: DateTime.now().toUtc(),
  );
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
      executable: claude,
      arguments: spec.argumentsFor(linux: Platform.isLinux),
      directory: EnvironmentPath(
        environmentId: environment.id,
        path: temp.path,
      ),
      environment: environment,
      // Run from inside Claude Code, the test must not look like it.
      removed: const {'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT'},
      risk: PermissionRisk.ask,
      resumeSessionId: resume,
    ),
  );
  List<SessionMessage> rows(String sessionId) => messages.listAfter(sessionId);
  String dump(String sessionId) {
    final buffer = StringBuffer(log.toString());
    for (final row in rows(sessionId)) {
      buffer.writeln(
        '  ${row.ordinal} ${row.role.name} text=${jsonEncode(row.text)} '
        'tool=${row.toolJson ?? '-'} plan=${row.planJson ?? '-'}',
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

  final first = start('live-claude-1');
  AcpSessionRuntime? second;
  try {
    final clock = Stopwatch()..start();
    final outcome = await first.start();
    note(
      'started in ${clock.elapsedMilliseconds} ms: session '
      '${outcome.agentSessionId}, notices ${outcome.notices}',
    );
    expect(outcome.resumed, isFalse);
    expect(first.modes!.currentModeId, 'default');
    final models = first.configOptions!.options.single;
    note('models: ${models.choices.map((c) => c.value).toList()}');
    expect(models.choices.map((c) => c.value), contains('haiku'));
    await first.setConfigOption('model', 'haiku');

    // A read-only turn.
    clock.reset();
    await first.send('Read hello.txt and reply with only its first word.');
    expect(
      await first.awaitTurn(),
      StopReason.endTurn,
      reason: dump('live-claude-1'),
    );
    note('turn 1 in ${clock.elapsedMilliseconds} ms');
    final reads = tools('live-claude-1').where((t) => t.kind == ToolKind.read);
    expect(reads, isNotEmpty, reason: dump('live-claude-1'));
    expect(reads.first.status, ToolCallStatus.completed);
    final reply = rows('live-claude-1')
        .where((r) => r.role == SessionMessageRole.agent)
        .map((r) => r.text)
        .join(' ');
    expect(
      reply.toLowerCase(),
      contains('banana'),
      reason: dump('live-claude-1'),
    );
    final usage = host.usage.last;
    note(
      'usage: ${usage.contextUsed}/${usage.contextSize}, '
      '${usage.costAmount} ${usage.costCurrency}',
    );
    expect(usage.contextSize, greaterThan(0));
    expect(usage.costAmount, greaterThan(0));

    // A write, denied.
    final before = rows('live-claude-1').length;
    await first.send(
      'Use your Write tool (not a shell) to create out.txt containing x. If '
      'it is refused, reply with the single word: refused',
    );
    var settled = false;
    unawaited(first.awaitTurn().whenComplete(() => settled = true));
    var asked = 0;
    while (!settled) {
      if (first.hasOpenPermission) {
        final answer = await first.answerPermission(approve: false);
        asked++;
        note('denied "${answer.toolTitle}" choosing "${answer.answered}"');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(asked, greaterThanOrEqualTo(1), reason: dump('live-claude-1'));
    expect(
      File('${temp.path}${Platform.pathSeparator}out.txt').existsSync(),
      isFalse,
    );
    final writes = tools(
      'live-claude-1',
    ).skip(0).where((t) => t.kind == ToolKind.edit);
    expect(writes.last.status, ToolCallStatus.failed);
    note(
      'rows after the denied write: ${rows('live-claude-1').length - before}',
    );

    // An interrupt mid-turn.
    await first.send(
      'Without tools, count from one to three hundred in words, one per line.',
    );
    final counting = Stopwatch()..start();
    while (!rows('live-claude-1').any((r) => r.text.contains('ten')) &&
        counting.elapsed < const Duration(seconds: 60)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    first.cancel();
    expect(
      await first.awaitTurn(),
      StopReason.cancelled,
      reason: dump('live-claude-1'),
    );
    note('interrupted after ${counting.elapsedMilliseconds} ms');

    final end = await first.stop();
    note('stopped: $end');

    // The conversation, resumed by id in a process of its own.
    second = start('live-claude-2', resume: outcome.agentSessionId);
    final resumed = await second.start();
    note('resumed: ${resumed.resumed}, notices ${resumed.notices}');
    expect(resumed.resumed, isTrue);
    await second.setConfigOption('model', 'haiku');
    await second.send(
      'Without tools: what was the first word of hello.txt, as you read it '
      'earlier in this conversation? Reply with the word only.',
    );
    expect(
      await second.awaitTurn(),
      StopReason.endTurn,
      reason: dump('live-claude-2'),
    );
    final remembered = rows('live-claude-2')
        .where((r) => r.role == SessionMessageRole.agent)
        .map((r) => r.text)
        .join(' ');
    expect(
      remembered.toLowerCase(),
      contains('banana'),
      reason: dump('live-claude-2'),
    );
    await second.stop();
  } finally {
    if (!first.lifecycle.hasEnded) await first.stop();
    if (second != null && !second.lifecycle.hasEnded) await second.stop();
    database.close();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // A process may still hold it for a moment on Windows.
    }
    stdout.write(log);
  }
}

String? _claudeBinary() {
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home != null) {
    final installed = File(
      Platform.isWindows
          ? '$home\\.local\\bin\\claude.exe'
          : '$home/.local/bin/claude',
    );
    if (installed.existsSync()) return installed.path;
  }
  return null;
}
