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
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../acp/acp_fixture.dart' show RecordingHost;

/// The server's ACP runtime over a real adapter in WSL, started exactly as
/// the launcher starts one: the real `CommandRunnerFactory` for a WSL
/// environment, `npx -y <adapter>`, a WSL temp folder as the working
/// directory. Opt-in: it spends model turns and needs WSL, npx and the
/// agent's own login, so it skips unless KARMASHALA_LIVE_ACP=1 and WSL
/// answers `command -v npx`. What no fake can measure: that the adapter's
/// file tools, permission requests and exit meet this runtime as designed.
void main() {
  final wsl = _Wsl.detect();
  final skip = wsl.skipReason;

  test(
    'claude-agent-acp under acceptEdits: start, a plain reply, a file '
    'written without asking, stop',
    () => _exercise(
      wsl,
      agentId: AgentIds.claudeAcp,
      agentName: 'Claude (ACP)',
      spec: claudeAcpDescriptor.acp!,
      package: '@agentclientprotocol/claude-agent-acp',
      risk: PermissionRisk.acceptEdits,
    ),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'claude-agent-acp under ask: the write asks permission, which the '
    'runtime holds for the checkpoint and answers',
    () => _exercise(
      wsl,
      agentId: AgentIds.claudeAcp,
      agentName: 'Claude (ACP)',
      spec: claudeAcpDescriptor.acp!,
      package: '@agentclientprotocol/claude-agent-acp',
      risk: PermissionRisk.ask,
      expectPermission: true,
    ),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'codex-acp under acceptEdits: start, a plain reply, a file written, stop',
    () => _exercise(
      wsl,
      agentId: AgentIds.codexAcp,
      agentName: 'Codex (ACP)',
      spec: codexAcpDescriptor.acp!,
      package: '@agentclientprotocol/codex-acp',
      risk: PermissionRisk.acceptEdits,
    ),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _exercise(
  _Wsl wsl, {
  required String agentId,
  required String agentName,
  required AcpLaunchSpec spec,
  required String package,
  required PermissionRisk risk,
  bool expectPermission = false,
}) async {
  final log = StringBuffer();
  void note(String line) {
    log.writeln('[${DateTime.now().toIso8601String()}] $line');
    stdout.writeln('acp-live $agentId: $line');
  }

  final environment = ExecutionEnvironment(
    id: 'wsl:${wsl.distribution}',
    kind: EnvironmentKind.wsl,
    name: wsl.distribution,
    wslDistribution: wsl.distribution,
    createdAt: DateTime.now().toUtc(),
  );
  final cwd = wsl.run('mktemp -d').trim();
  expect(cwd, startsWith('/'), reason: 'mktemp in WSL');
  note('working directory $cwd');

  final database = AppDatabase.memory();
  database.execute('PRAGMA foreign_keys = OFF;');
  const sessionId = 'live-acp-s1';
  SessionDao(database).insert(
    Session(
      id: sessionId,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'live acp',
      useWorktree: false,
      workingDirectory: EnvironmentPath(
        environmentId: environment.id,
        path: cwd,
      ),
      status: SessionStatus.running,
      createdAt: DateTime.now().toUtc(),
    ),
  );
  final messages = SessionMessageDao(database);
  final host = RecordingHost();
  final runtimes = AcpRuntimes(
    messages: messages,
    host: host,
    runnerFor: (env) => const CommandRunnerFactory().forEnvironment(env!),
  );
  final runtime = runtimes.start(
    AcpSessionStart(
      sessionId: sessionId,
      hostSessionId: 'karmashala_$sessionId',
      agentId: agentId,
      agentName: agentName,
      spec: spec,
      executable: 'npx',
      arguments: ['-y', package],
      directory: EnvironmentPath(environmentId: environment.id, path: cwd),
      environment: environment,
      variables: const {'KARMASHALA_SESSION_ID': sessionId},
      risk: risk,
    ),
  );

  List<AgentActivityStatus> statuses() => [
    for (final report in host.statuses) report.status,
  ];
  List<SessionMessage> rows() => messages.listAfter(sessionId);
  String dump() {
    final buffer = StringBuffer(log.toString());
    buffer.writeln('rows:');
    for (final row in rows()) {
      buffer.writeln(
        '  ${row.ordinal} ${row.role.name} text=${jsonEncode(row.text)} '
        'thinking=${row.thinking == null ? '-' : row.thinking!.length} '
        'tool=${row.toolJson ?? '-'}',
      );
    }
    buffer.writeln('statuses: ${statuses().map((s) => s.name).join(' > ')}');
    buffer.writeln('logged: ${host.logged}');
    return buffer.toString();
  }

  try {
    // Start.
    final started = Stopwatch()..start();
    AcpStartOutcome outcome;
    try {
      outcome = await runtime.start();
    } on StateError catch (error) {
      if (error.message.contains('authenticated')) {
        fail(
          '$agentName refused the session until it is logged in; log in to it '
          'inside WSL and rerun. Its words: ${error.message}',
        );
      }
      rethrow;
    }
    note(
      'started in ${started.elapsedMilliseconds} ms: agent session id '
      '"${outcome.agentSessionId}", resumed=${outcome.resumed}, notices '
      '${outcome.notices}',
    );
    expect(outcome.agentSessionId, isNotEmpty);
    expect(outcome.resumed, isFalse);
    expect(runtime.agentSessionId, outcome.agentSessionId);
    final announced = runtime.modes;
    note(
      'modes: current ${announced?.currentModeId}, available '
      '${announced?.availableModes.map((m) => m.id).toList()}',
    );
    expect(host.modes, isNotEmpty, reason: 'modes are announced on start');
    expect(statuses(), [AgentActivityStatus.idle]);
    expect(host.statuses.single.source, AgentStatusSource.protocol);

    // A plain reply.
    final turn1 = Stopwatch()..start();
    await runtime.send('Reply with exactly the word: hello');
    final reason1 = await runtime.awaitTurn();
    note('turn 1 ended ${reason1?.raw} in ${turn1.elapsedMilliseconds} ms');
    expect(reason1, StopReason.endTurn, reason: dump());
    final afterOne = rows();
    expect(afterOne.first.role, SessionMessageRole.user, reason: dump());
    expect(afterOne.first.text, 'Reply with exactly the word: hello');
    final reply = afterOne.where(
      (row) => row.role == SessionMessageRole.agent && row.text.isNotEmpty,
    );
    expect(reply, isNotEmpty, reason: dump());
    expect(
      reply.map((row) => row.text.toLowerCase()).join(' '),
      contains('hello'),
      reason: dump(),
    );
    expect(statuses(), [
      AgentActivityStatus.idle,
      AgentActivityStatus.working,
      AgentActivityStatus.idle,
    ], reason: dump());
    expect(host.messagesChangedCount, greaterThanOrEqualTo(2));
    expect(host.prompts, ['Reply with exactly the word: hello']);
    final rowsAfterOne = afterOne.length;

    // A file written in the working directory.
    final turn2 = Stopwatch()..start();
    await runtime.send(
      'Create a file named note.txt in the current working directory '
      'containing exactly the word done, using your file writing tool (not a '
      'shell command). Then reply with the single word: written',
    );
    var settled = false;
    unawaited(runtime.awaitTurn().whenComplete(() => settled = true));
    var permissionsAnswered = 0;
    while (!settled) {
      if (runtime.hasOpenPermission) {
        final call = runtime.pendingToolCallId;
        final answer = await runtime.answerPermission(approve: true);
        permissionsAnswered++;
        note(
          'permission for "${answer.toolTitle}" (call $call) answered '
          '"${answer.answered}"',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final reason2 = await runtime.awaitTurn();
    note(
      'turn 2 ended (${turn2.elapsedMilliseconds} ms), '
      '$permissionsAnswered permission(s) answered; checkpointSettled '
      '${host.settledCalls}x, touched ${host.touched}',
    );
    expect(reason2, isNull, reason: 'no turn is open once settled');
    final afterTwo = rows().skip(rowsAfterOne).toList();
    final toolRows = [
      for (final row in afterTwo)
        if (row.toolJson != null)
          ToolCallUpdate.fromJson(
            jsonDecode(row.toolJson!) as Map<String, Object?>,
            isNew: true,
          ),
    ];
    note(
      'tool rows: ${toolRows.map((t) => '${t.title ?? t.name} '
          'kind=${t.kind?.raw} status=${t.status?.raw} '
          'locations=${t.locations?.map((l) => l.path).toList()}').toList()}',
    );
    final content = wsl.run('cat $cwd/note.txt; echo; echo "exit=\$?"');
    note('note.txt in WSL: ${jsonEncode(content)}');
    expect(
      content.trim().split('\n').first.trim().toLowerCase(),
      'done',
      reason: 'the file the agent wrote exists where it works\n${dump()}',
    );
    final edits = toolRows.where(
      (t) => t.kind == ToolKind.edit && t.status == ToolCallStatus.completed,
    );
    expect(edits, isNotEmpty, reason: 'a completed edit tool row\n${dump()}');
    expect(
      host.touched.any((path) => path.endsWith('note.txt')),
      isTrue,
      reason: 'the checkpoint is told what was touched: ${host.touched}',
    );
    expect(statuses().last, AgentActivityStatus.idle, reason: dump());
    if (expectPermission) {
      expect(
        permissionsAnswered,
        greaterThanOrEqualTo(1),
        reason: 'under "${risk.label}" the write asks first\n${dump()}',
      );
    }
    if (permissionsAnswered > 0) {
      expect(statuses(), contains(AgentActivityStatus.awaitingApproval));
      final waiting = host.statuses.firstWhere(
        (r) => r.status == AgentActivityStatus.awaitingApproval,
      );
      note(
        'waiting status: toolAsk ${waiting.toolAsk?.toolName} '
        '${waiting.toolAsk?.input}, evidence ${waiting.evidence}',
      );
      expect(waiting.waiting, AgentWaitKind.approval);
      expect(waiting.toolAsk, isNotNull);
      // Only an approved edit, or an fs/write, waits for the checkpoint:
      // an agent writing with its own tools under acceptEdits never does.
      expect(
        host.settledCalls,
        greaterThanOrEqualTo(1),
        reason: 'an approved edit waits for the before-turn checkpoint',
      );
    }

    // Stop.
    final stopping = Stopwatch()..start();
    final end = await runtime.stop();
    stopping.stop();
    note('stopped in ${stopping.elapsedMilliseconds} ms: $end');
    expect(runtime.lifecycle.hasEnded, isTrue);
    expect(await runtime.ended, end);
    expect(
      stopping.elapsed,
      lessThan(runtime.stopPatience * 2 + const Duration(seconds: 2)),
      reason: 'stop waits stopPatience to exit and stopPatience after a kill',
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final lingering = wsl.run(
      'for p in /proc/[0-9]*; do readlink \$p/cwd 2>/dev/null; done '
      '| grep -c "^$cwd" || true',
    );
    note('processes still in $cwd after stop: ${lingering.trim()}');
    expect(
      int.tryParse(lingering.trim()) ?? -1,
      0,
      reason: 'no process of the agent is left working in $cwd',
    );
  } finally {
    if (!runtime.lifecycle.hasEnded) await runtime.stop();
    database.close();
    wsl.run('rm -rf $cwd');
    stdout.write(log);
  }
}

/// WSL as this machine has it, and the reason the test cannot run.
class _Wsl {
  _Wsl._(this.distribution, this.skipReason);

  final String distribution;
  final String? skipReason;

  static _Wsl detect() {
    if (Platform.environment['KARMASHALA_LIVE_ACP'] != '1') {
      return _Wsl._('', 'set KARMASHALA_LIVE_ACP=1 to run the real adapters');
    }
    if (!Platform.isWindows) return _Wsl._('', 'drives WSL through wsl.exe');
    String distribution;
    try {
      final listed = Process.runSync('wsl.exe', [
        '-l',
        '-q',
      ], stdoutEncoding: null);
      final names = _utf16(listed.stdout as List<int>)
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('docker-'))
          .toList();
      if (listed.exitCode != 0 || names.isEmpty) {
        return _Wsl._('', 'wsl.exe lists no distribution');
      }
      distribution = names.first;
    } on ProcessException catch (error) {
      return _Wsl._('', 'wsl.exe is not available: ${error.message}');
    }
    final npx = Process.runSync('wsl.exe', [
      '-d',
      distribution,
      '--',
      'sh',
      '-c',
      'command -v npx',
    ]);
    if (npx.exitCode != 0) {
      return _Wsl._(distribution, 'WSL "$distribution" has no npx on PATH');
    }
    return _Wsl._(distribution, null);
  }

  /// `wsl -l -q` writes UTF-16LE; decoded by hand so no code page applies.
  static String _utf16(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units).replaceAll('\u0000', '');
  }

  /// Runs [script] with `sh` inside the distribution, as a file: a line with
  /// quotes does not survive Windows rebuilding the command line.
  String run(String script) {
    final file = File(
      '${Directory.systemTemp.path}\\acp-live-'
      '${DateTime.now().microsecondsSinceEpoch}.sh',
    )..writeAsStringSync('${script.replaceAll('\r\n', '\n')}\n');
    try {
      final result = Process.runSync('wsl.exe', [
        '-d',
        distribution,
        '--',
        'sh',
        const PathTranslator().windowsDriveToWslMount(file.path),
      ]);
      return '${result.stdout}${result.stderr}';
    } finally {
      file.deleteSync();
    }
  }
}
