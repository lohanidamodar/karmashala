@Tags(['live-acp'])
library;

import 'dart:async';
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

/// Codex's chat over the real `codex app-server`, through the codexAppServer
/// bridge, started as the launcher starts it. Opt-in: it spends model turns
/// and needs Codex logged in, so it skips unless KARMASHALA_LIVE_ACP=1 and
/// `codex` is found (or named by KARMASHALA_CODEX); the WSL case also needs
/// a distribution (KARMASHALA_WSL_DISTRO, else the first) with codex on its
/// login PATH.
void main() {
  final codex = _windowsCodex();
  final wsl = _wslCodex();

  test(
    'a read-only turn reads a file, then the thread resumes in a new process',
    () => _readAndResume(_Live.local(codex.path!)),
    skip: codex.skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'in ask mode a write outside the workspace asks: approved it is made, '
    'rejected it is not',
    () => _approval(_Live.local(codex.path!)),
    skip: codex.skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'an interrupt mid-turn ends the turn cancelled, long before the command',
    () => _interrupt(_Live.local(codex.path!)),
    skip: codex.skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'the same read-only turn with Codex in WSL',
    () => _readInWsl(wsl.distribution!, wsl.path!),
    skip: wsl.skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

({String? path, String? skip}) _windowsCodex() {
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

({String? distribution, String? path, String? skip}) _wslCodex() {
  if (Platform.environment['KARMASHALA_LIVE_ACP'] != '1') {
    return (
      distribution: null,
      path: null,
      skip: 'set KARMASHALA_LIVE_ACP=1 to run real Codex',
    );
  }
  if (!Platform.isWindows) {
    return (distribution: null, path: null, skip: 'drives WSL via wsl.exe');
  }
  var distribution = Platform.environment['KARMASHALA_WSL_DISTRO'] ?? '';
  if (distribution.isEmpty) {
    final listed = Process.runSync('wsl.exe', [
      '-l',
      '-q',
    ], stdoutEncoding: null);
    final names = String.fromCharCodes(
      (listed.stdout as List<int>).where((b) => b != 0),
    ).split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty);
    distribution =
        names.where((n) => !n.startsWith('docker-')).firstOrNull ?? '';
  }
  if (distribution.isEmpty) {
    return (distribution: null, path: null, skip: 'no WSL distribution');
  }
  final found = Process.runSync('wsl.exe', [
    '-d',
    distribution,
    '--',
    'sh',
    '-lc',
    'command -v codex',
  ]);
  final path = '${found.stdout}'.trim();
  if (found.exitCode != 0 || !path.startsWith('/')) {
    return (
      distribution: null,
      path: null,
      skip: 'WSL "$distribution" has no codex on its login PATH',
    );
  }
  return (distribution: distribution, path: path, skip: null);
}

/// One machine's Codex, started through the launcher's runtimes.
class _Live {
  _Live(this.codex, this.environment, this.directory);

  factory _Live.local(String codex) {
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
    return _Live(codex, environment, temp.path);
  }

  final String codex;
  final ExecutionEnvironment environment;
  final String directory;
  final log = StringBuffer();
  final database = AppDatabase.memory()..execute('PRAGMA foreign_keys = OFF;');
  late final messages = SessionMessageDao(database);
  final host = RecordingHost();
  late final runtimes = AcpRuntimes(
    messages: messages,
    usage: SessionUsageDao(database),
    host: host,
    runnerFor: (env) => const CommandRunnerFactory().forEnvironment(env!),
  );

  void note(String line) {
    log.writeln(line);
    stdout.writeln('codex-live: $line');
  }

  AcpSessionRuntime open(
    String sessionId, {
    PermissionRisk risk = PermissionRisk.readOnly,
    String? resume,
  }) {
    final spec = codexAcpDescriptor.acp!;
    return runtimes.start(
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
          path: directory,
        ),
        environment: environment,
        variables: {'KARMASHALA_SESSION_ID': sessionId},
        risk: risk,
        resumeSessionId: resume,
      ),
    );
  }

  List<ToolCallUpdate> tools(String sessionId) => [
    for (final row in messages.listAfter(sessionId))
      if (row.toolJson != null)
        ToolCallUpdate.fromJson(
          jsonDecode(row.toolJson!) as Map<String, Object?>,
          isNew: true,
        ),
  ];

  String said(String sessionId) => messages
      .listAfter(sessionId)
      .where((r) => r.role == SessionMessageRole.agent)
      .map((r) => r.text)
      .join(' ');

  String dump(String sessionId) {
    final buffer = StringBuffer(log.toString());
    for (final row in messages.listAfter(sessionId)) {
      buffer.writeln(
        '  ${row.role.name} text=${jsonEncode(row.text)} '
        'tool=${row.toolJson ?? '-'}',
      );
    }
    buffer.writeln(
      'statuses: ${host.statuses.map((s) => s.status.name).join(' > ')}',
    );
    return buffer.toString();
  }

  void noteTools(String sessionId) {
    for (final tool in tools(sessionId)) {
      note(
        'tool "${tool.title}" kind=${tool.kind?.raw} '
        'status=${tool.status?.raw} input=${jsonEncode(tool.rawInput)}',
      );
    }
  }

  void close() {
    database.close();
    if (environment.kind == EnvironmentKind.wsl) return;
    try {
      Directory(directory).deleteSync(recursive: true);
    } on FileSystemException {
      // Codex's sandbox helper may still hold the folder for a moment.
    }
  }
}

Future<void> _readAndResume(_Live live) async {
  try {
    final first = live.open('live-codex-1');
    final outcome = await first.start();
    live.note(
      'started: thread ${outcome.agentSessionId}, notices ${outcome.notices}',
    );
    expect(outcome.resumed, isFalse);
    expect(first.modes?.currentModeId, 'read-only');
    for (final option in first.configOptions!.options) {
      live.note(
        'option ${option.id} = ${option.currentValue} of '
        '${option.choices.map((c) => c.value).toList()}',
      );
    }
    await first.send(
      'Read hello.txt with a shell command, then reply with its contents '
      'and nothing else. Do not change any file.',
    );
    final reason = await first.awaitTurn();
    live.note('turn ended ${reason?.raw}');
    expect(reason, StopReason.endTurn, reason: live.dump('live-codex-1'));
    live.noteTools('live-codex-1');
    expect(live.tools('live-codex-1'), isNotEmpty);
    live.note('reply: ${jsonEncode(live.said('live-codex-1'))}');
    expect(live.said('live-codex-1'), contains('karmashala live probe'));
    expect(live.host.usage, isNotEmpty);
    expect(
      Directory(live.directory).listSync().map((e) => e.uri.pathSegments.last),
      ['hello.txt'],
      reason: 'a read-only turn changes nothing',
    );
    await first.stop();

    final second = live.open('live-codex-2', resume: outcome.agentSessionId);
    final resumed = await second.start();
    live.note('resumed=${resumed.resumed}');
    expect(resumed.resumed, isTrue, reason: live.dump('live-codex-2'));
    await second.send(
      'Which file did you read in this conversation? Reply with its name only.',
    );
    expect(await second.awaitTurn(), StopReason.endTurn);
    live.note('recalled: ${jsonEncode(live.said('live-codex-2'))}');
    expect(live.said('live-codex-2'), contains('hello.txt'));
    await second.stop();
  } finally {
    live.close();
  }
}

/// Runs a turn, answering every permission it asks with [approve].
Future<int> _turnAnswering(
  _Live live,
  AcpSessionRuntime runtime,
  String prompt, {
  required bool approve,
}) async {
  await runtime.send(prompt);
  var settled = false;
  unawaited(runtime.awaitTurn().whenComplete(() => settled = true));
  var answered = 0;
  while (!settled) {
    if (runtime.hasOpenPermission) {
      final waiting = live.host.statuses.last.toolAsk;
      final answer = await runtime.answerPermission(approve: approve);
      answered++;
      live.note(
        'asked about "${waiting?.toolName}" ${jsonEncode(waiting?.input)}; '
        'answered "${answer.answered}"',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return answered;
}

Future<void> _approval(_Live live) async {
  // Outside the workspace and the temp folder, where ask mode
  // (workspace-write) cannot write without asking.
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!;
  final outside = Directory(home).createTempSync('.karmashala-live-');
  try {
    final runtime = live.open('live-codex-ask', risk: PermissionRisk.ask);
    await runtime.start();
    live.note('mode ${runtime.modes?.currentModeId}');
    expect(runtime.modes?.currentModeId, 'workspace-write');

    final approved = File(
      '${outside.path}${Platform.pathSeparator}approved.txt',
    );
    final asked = await _turnAnswering(
      live,
      runtime,
      'Using one shell command, create the file ${approved.path} containing '
      'the word yes. It is outside your workspace, so run that command with '
      'escalated permissions. Then reply with the single word: done',
      approve: true,
    );
    live.noteTools('live-codex-ask');
    live.note(
      'approved turn: $asked asked; file there: ${approved.existsSync()}',
    );
    expect(asked, greaterThanOrEqualTo(1), reason: live.dump('live-codex-ask'));
    expect(approved.existsSync(), isTrue, reason: live.dump('live-codex-ask'));

    final rejected = File(
      '${outside.path}${Platform.pathSeparator}rejected.txt',
    );
    final askedAgain = await _turnAnswering(
      live,
      runtime,
      'Using one shell command, create the file ${rejected.path} containing '
      'the word no. It is outside your workspace, so run that command with '
      'escalated permissions. If you are not allowed, do not try another '
      'way; reply with the single word: refused',
      approve: false,
    );
    live.noteTools('live-codex-ask');
    live.note(
      'rejected turn: $askedAgain asked; file there: ${rejected.existsSync()}',
    );
    expect(askedAgain, greaterThanOrEqualTo(1));
    expect(rejected.existsSync(), isFalse, reason: live.dump('live-codex-ask'));
    await runtime.stop();
  } finally {
    live.close();
    try {
      outside.deleteSync(recursive: true);
    } on FileSystemException {
      // Held a moment longer by the sandbox; it is empty or nearly so.
    }
  }
}

Future<void> _interrupt(_Live live) async {
  try {
    final runtime = live.open('live-codex-stop', risk: PermissionRisk.autoRun);
    await runtime.start();
    final clock = Stopwatch()..start();
    await runtime.send(
      'Run a shell command that waits 90 seconds (for example '
      '`Start-Sleep -Seconds 90` in PowerShell or `sleep 90`), then reply '
      'with the single word: awake',
    );
    // Cancelled once the command is running, or after 30 s regardless.
    while (clock.elapsed < const Duration(seconds: 30) &&
        !live
            .tools('live-codex-stop')
            .any((t) => t.status?.raw == 'in_progress')) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    live.noteTools('live-codex-stop');
    live.note('cancelling at ${clock.elapsed.inMilliseconds} ms');
    runtime.cancel();
    final reason = await runtime.awaitTurn();
    live.note(
      'turn ended ${reason?.raw} at ${clock.elapsed.inMilliseconds} ms',
    );
    expect(reason, StopReason.cancelled, reason: live.dump('live-codex-stop'));
    expect(clock.elapsed, lessThan(const Duration(seconds: 80)));
    live.noteTools('live-codex-stop');
    await runtime.stop();
  } finally {
    live.close();
  }
}

Future<void> _readInWsl(String distribution, String codex) async {
  String run(String script) {
    final result = Process.runSync('wsl.exe', [
      '-d',
      distribution,
      '--',
      'sh',
      '-c',
      script,
    ]);
    return '${result.stdout}'.trim();
  }

  final directory = run('mktemp -d');
  expect(directory, startsWith('/'));
  run("printf 'karmashala wsl probe\\n' > $directory/hello.txt");
  final live = _Live(
    codex,
    ExecutionEnvironment(
      id: 'wsl:$distribution',
      kind: EnvironmentKind.wsl,
      name: distribution,
      wslDistribution: distribution,
      createdAt: DateTime.now().toUtc(),
    ),
    directory,
  );
  try {
    final runtime = live.open('live-codex-wsl');
    final outcome = await runtime.start();
    live.note(
      'WSL thread ${outcome.agentSessionId}, mode '
      '${runtime.modes?.currentModeId}',
    );
    await runtime.send(
      'Read hello.txt with a shell command, then reply with its contents '
      'and nothing else. Do not change any file.',
    );
    final reason = await runtime.awaitTurn();
    live.note('turn ended ${reason?.raw}');
    expect(reason, StopReason.endTurn, reason: live.dump('live-codex-wsl'));
    live.noteTools('live-codex-wsl');
    live.note('reply: ${jsonEncode(live.said('live-codex-wsl'))}');
    expect(live.said('live-codex-wsl'), contains('karmashala wsl probe'));
    expect(run('ls $directory'), 'hello.txt');
    await runtime.stop();
  } finally {
    live.close();
    run('rm -rf $directory');
  }
}
