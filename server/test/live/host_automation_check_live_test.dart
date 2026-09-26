@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

import 'local_host_harness.dart';

/// The run that froze a host on 2026-09-25, end to end on a real `serve`: a
/// scheduled automation starts an agent that stops at Claude Code's trust
/// question, the first-run watch fails the run, and the project check —
/// `test -f README.md`, a bare name found on PATH — runs in a session the host
/// owns. The host must keep answering its socket and its MCP port through all
/// of it, and the check must record its pass.
void main() {
  test('an unattended run blocked at the trust question, then its check: the '
      'host keeps answering and the check passes', () async {
    final home = temporaryHome('karmashala-host-auto');
    final data = Directory('${home.path}/data')..createSync();
    final checkout = Directory('${home.path}/shop')..createSync();
    File('${checkout.path}/README.md').writeAsStringSync('# Shop\n');
    // A checkout the base checkpoint can take, as a real one is.
    for (final args in [
      ['init', '-q'],
      ['-c', 'user.email=t@t', '-c', 'user.name=t', 'add', '.'],
      [
        '-c',
        'user.email=t@t',
        '-c',
        'user.name=t',
        'commit',
        '-q',
        '-m',
        'init',
      ],
    ]) {
      final git = await Process.run(
        'git',
        args,
        workingDirectory: checkout.path,
      );
      expect(git.exitCode, 0, reason: '${git.stdout}${git.stderr}');
    }

    // The agent: draws the trust question, then waits for an answer that
    // nobody gives.
    final agent = File('${home.path}/bin/claude')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'printf " Accessing workspace:\\r\\n\\r\\n %s\\r\\n\\r\\n" "\$PWD"\n'
        'printf " Quick safety check: Is this a project you created or one '
        'you trust? (Like your\\r\\n own code, a well-known open source '
        'project, or work from your team).\\r\\n\\r\\n"\n'
        'printf " \\342\\235\\257 1. Yes, I trust this folder\\r\\n   2. No, '
        'exit\\r\\n\\r\\n Enter to confirm \\302\\267 Esc to cancel\\r\\n"\n'
        'exec sleep 600\n',
      );
    expect((await Process.run('chmod', ['755', agent.path])).exitCode, 0);

    // Due only after the app has "quit" below, so the run fires with nobody
    // reading what the host prints — as it did on 2026-09-25.
    final dueAt = DateTime.now().toUtc().add(const Duration(seconds: 8));
    _seed(data, checkout: checkout.path, agent: agent.path, dueAt: dueAt);

    final host = await LocalHost.start(home);
    addTearDown(host.kill);
    expect(host.greeting, contains('automations scheduled here'));
    final mcpPort = int.parse(
      RegExp(r'agent tools on port (\d+)').firstMatch(host.greeting)!.group(1)!,
    );
    // The app that started it goes away: its ends of the host's stdout and
    // stderr close, and the host's next log line has nowhere to go.
    await host.hangUpOutput();

    final client = await LocalHostClient.connect(host.socketPath, 'probe');
    addTearDown(client.close);
    await client.expect<WelcomeMessage>();

    // Watch the database until the run has failed and its check recorded.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    AutomationRun? run;
    List<AutomationCheckVerdict> verdicts = const [];
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final db = AppDatabase.open(data);
      try {
        final dao = AutomationDao(db);
        final runs = dao.runsFor('auto-1');
        run = runs.isEmpty ? null : runs.single;
        verdicts = run == null ? const [] : dao.checksFor(run.id);
      } finally {
        db.close();
      }
      if (verdicts.isNotEmpty) break;
    }
    expect(run, isNotNull, reason: await _diagnose(host));
    expect(run!.state, AutomationRunState.failed);
    expect(run.reason, contains('is asking whether to trust'));
    expect(
      verdicts,
      hasLength(1),
      reason: 'the check never recorded\n${await _diagnose(host)}',
    );
    expect(verdicts.single.verdict, VerificationVerdict.pass);

    // Still answering: the socket, a fresh handshake, and the MCP port.
    client.send(ListMessage(client.nextId()));
    final SessionsMessage listed;
    try {
      listed = await client.expect<SessionsMessage>(
        within: const Duration(seconds: 5),
      );
    } on TimeoutException {
      fail('the host stopped answering\n${await _diagnose(host)}');
    }
    final agentSession = listed.summaries.singleWhere(
      (s) => s.id.startsWith('karmashala_'),
    );
    expect(agentSession.lifecycle.hasEnded, isFalse);
    expect(
      listed.summaries.where((s) => s.id.startsWith(kCheckSessionPrefix)),
      isEmpty,
      reason: 'a check session is let go once its verdict is taken',
    );

    final second = await LocalHostClient.connect(host.socketPath, 'probe-2');
    addTearDown(second.close);
    await second.expect<WelcomeMessage>(within: const Duration(seconds: 5));

    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    addTearDown(http.close);
    final request = await http
        .get('127.0.0.1', mcpPort, '/')
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    expect(response.statusCode, greaterThan(0));

    // More checks on the same host, one after another: no stall either.
    for (var i = 0; i < 3; i++) {
      client.send(
        OpenMessage(
          requestId: client.nextId(),
          sessionId: 'again-$i',
          argv: const ['test', '-f', 'README.md'],
          workingDirectory: checkout.path,
          environment: const {'TERM': 'xterm-256color'},
          columns: 80,
          rows: 24,
        ),
      );
      await client.expect<AttachedMessage>(within: const Duration(seconds: 5));
      final exited = await client.expect<ExitedMessage>(
        within: const Duration(seconds: 5),
      );
      expect(exited.exitCode, 0);
    }

    // And it stops when asked, promptly: with the agent still at its
    // question and two clients still connected.
    host.process.kill(ProcessSignal.sigterm);
    final code = await host.process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () => -999,
    );
    expect(
      code,
      isNot(-999),
      reason: 'serve lingered after SIGTERM\n${await _diagnose(host)}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// What the host is doing, for a failure message: its threads, its files and
/// its children on macOS, and everything it said.
Future<String> _diagnose(LocalHost host) async {
  final pid = host.process.pid;
  final said = StringBuffer('host said:\n${host.output}\n');
  if (!Platform.isMacOS) return said.toString();
  final sample = await Process.run('/usr/bin/sample', ['$pid', '1']);
  final text = '${sample.stdout}';
  final cut = text.indexOf('Binary Images');
  said.writeln('sample:\n${cut < 0 ? text : text.substring(0, cut)}');
  final lsof = await Process.run('/usr/sbin/lsof', ['-p', '$pid']);
  said.writeln('lsof:\n${lsof.stdout}');
  final ps = await Process.run('/bin/ps', [
    '-A',
    '-o',
    'pid,ppid,stat,lstart,command',
  ]);
  final children = '${ps.stdout}'
      .split('\n')
      .where((line) => line.contains(' $pid '))
      .join('\n');
  said.writeln('children:\n$children');
  return said.toString();
}

void _seed(
  Directory data, {
  required String checkout,
  required String agent,
  required DateTime dueAt,
}) {
  final db = AppDatabase.open(data);
  try {
    db.execute('PRAGMA foreign_keys = OFF;');
    final at = DateTime.now().toUtc().toIso8601String();
    db.execute(
      'INSERT OR IGNORE INTO execution_environments (id, kind, name, '
      'created_at) VALUES (?, ?, ?, ?);',
      ['local', 'localPosix', 'this machine', at],
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      'created_at) VALUES (?, ?, ?, ?, ?);',
      ['p1', 'Shop', 'local', checkout, at],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop', 'local', checkout, at],
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, 0);',
      ['a1', AgentIds.claudeCode, 'local', agent, at],
    );
    final now = DateTime.now().toUtc();
    ProjectCheckDao(db)
      ..setVerificationEnabled('r1', enabled: true, now: now)
      ..insert(
        ProjectCheck(
          id: 'check-1',
          repositoryId: 'r1',
          name: 'readme',
          command: const ['test', '-f', 'README.md'],
          createdAt: now,
        ),
      );
    AutomationDao(db).insert(
      Automation(
        id: 'auto-1',
        repositoryId: 'r1',
        name: 'Soon',
        schedule: AutomationSchedule.once(dueAt),
        agentInstallationId: 'a1',
        prompt: 'Fix what broke.',
        permissionMode: const PermissionSelection({
          'mode': 'bypassPermissions',
        }),
        enabled: true,
        armedAt: now.subtract(const Duration(minutes: 1)),
        latePolicy: AutomationLatePolicy.run,
      ),
    );
  } finally {
    db.close();
  }
}
