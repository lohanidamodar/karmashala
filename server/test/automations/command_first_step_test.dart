import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runner.dart' show StepCommandResult;
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/step_runners.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// A command as an automation's first step, at the server: which shell runs
/// it where, the folder it runs in, and that a value never becomes syntax.
void main() {
  final at = DateTime.utc(2026, 10, 17);

  Automation command(
    String text, {
    AutomationShell shell = AutomationShell.login,
    EnvironmentPath? folder,
  }) => Automation(
    id: 'a1',
    repositoryId: folder == null ? 'r1' : '',
    name: 'Sync',
    schedule: AutomationSchedule.once(at),
    agentInstallationId: '',
    prompt: '',
    permissionMode: null,
    enabled: true,
    armedAt: at,
    command: AutomationCommand(text: text, shell: shell),
    folder: folder,
  );

  ExecutionEnvironment place(EnvironmentKind kind) => ExecutionEnvironment(
    id: kind.name,
    kind: kind,
    name: kind.name,
    createdAt: at,
    wslDistribution: kind == EnvironmentKind.wsl ? 'archlinux' : null,
  );

  File noBatch() => throw StateError('no batch file');

  group('the request', () {
    test('WSL and SSH run it in the login shell, command and folder as '
        'arguments', () {
      const text = r'git pull; echo "$KARMASHALA_AUTOMATION" & date';
      for (final kind in [EnvironmentKind.wsl, EnvironmentKind.ssh]) {
        final asked = commandRequest(
          command(text),
          place(kind),
          EnvironmentPath(environmentId: kind.name, path: '~/notes'),
          command: text,
          environment: const {'KARMASHALA_AUTOMATION': 'Sync'},
          timeout: const Duration(minutes: 1),
          batchFile: noBatch,
        ).request;
        expect(asked.executable, 'sh');
        expect(asked.arguments, [
          '-c',
          kLoginShellScript,
          'karmashala',
          text,
          '~/notes',
        ]);
        expect(asked.workingDirectory, isNull, reason: 'the script moves');
        expect(asked.environment['KARMASHALA_AUTOMATION'], 'Sync');
      }
    });

    test('the login script reads its command and folder only as values', () {
      expect(kLoginShellScript, contains(r'exec "$s" -lc "$1"'));
      expect(kLoginShellScript, contains(r'cd -- "$d"'));
    });

    test('a step in a checkout keeps running in sh, as before', () {
      final step = command('make').copyWith(clearCommand: true);
      final asked = commandRequest(
        step,
        place(EnvironmentKind.wsl),
        const EnvironmentPath(environmentId: 'wsl', path: '/src/app'),
        command: 'make',
        environment: const {},
        timeout: const Duration(minutes: 1),
        batchFile: noBatch,
      ).request;
      expect(asked.arguments, ['-c', 'make']);
      expect(asked.workingDirectory!.path, '/src/app');
    });

    test('Windows runs PowerShell from the folder, ~ read as home', () {
      final asked = commandRequest(
        command('Get-Date', shell: AutomationShell.powershell),
        place(EnvironmentKind.windowsNative),
        const EnvironmentPath(environmentId: 'windowsNative', path: r'~\notes'),
        command: 'Get-Date',
        environment: const {},
        timeout: const Duration(minutes: 1),
        batchFile: noBatch,
        hostEnvironment: const {'USERPROFILE': r'C:\Users\you'},
      ).request;
      expect(asked.executable, 'powershell.exe');
      expect(asked.arguments.last, 'Get-Date');
      expect(asked.workingDirectory!.path, r'C:\Users\you\notes');
    });

    test(
      'cmd runs a batch file with delayed expansion, removed after',
      () async {
        final folder = Directory.systemTemp.createTempSync('cmd-batch-');
        addTearDown(() => folder.deleteSync(recursive: true));
        final file = File('${folder.path}${Platform.pathSeparator}run.cmd');
        final made = commandRequest(
          command(
            'echo !KARMASHALA_AUTOMATION!\ndate /t',
            shell: AutomationShell.cmd,
          ),
          place(EnvironmentKind.windowsNative),
          const EnvironmentPath(environmentId: 'windowsNative', path: '~'),
          command: 'echo !KARMASHALA_AUTOMATION!\ndate /t',
          environment: const {},
          timeout: const Duration(minutes: 1),
          batchFile: () => file,
          hostEnvironment: const {'USERPROFILE': r'C:\Users\you'},
        );
        expect(made.request.executable, 'cmd.exe');
        expect(made.request.arguments, ['/d', '/c', 'call', file.path]);
        expect(made.request.workingDirectory!.path, r'C:\Users\you');
        expect(
          file.readAsStringSync(),
          '@echo off\r\nsetlocal EnableDelayedExpansion\r\n'
          'echo !KARMASHALA_AUTOMATION!\r\ndate /t\r\n',
        );
        await made.cleanUp();
        expect(file.existsSync(), isFalse);
      },
    );

    test('~ is home only at the start', () {
      expect(homeExpanded('~', r'C:\h'), r'C:\h');
      expect(homeExpanded('~/a', r'C:\h'), r'C:\h\a');
      expect(homeExpanded(r'D:\~x', r'C:\h'), r'D:\~x');
      expect(homeExpanded('~', null), '~');
    });
  });

  group('on this machine', () {
    final windows = Platform.isWindows;
    late AppDatabase db;
    late Directory folder;
    late ServerStepCommands commands;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('command-first-');
      db = AppDatabase.memory();
      db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('local', ?, 'this machine', ?);",
        [windows ? 'windowsNative' : 'localPosix', at.toIso8601String()],
      );
      commands = ServerStepCommands(
        facts: DaemonCheckoutFacts(CheckoutRows(db), windows: windows),
        sessionOf: (_) => null,
      );
    });
    tearDown(() async {
      db.close();
      for (var attempt = 0; ; attempt++) {
        try {
          folder.deleteSync(recursive: true);
          return;
        } on FileSystemException {
          if (attempt == 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    });

    final run = AutomationRun(
      id: 'run1',
      automationId: 'a1',
      scheduledFor: at,
      firedAt: at,
      state: AutomationRunState.running,
      reason: '',
    );
    const hostile = 'a & echo INJECTED > pwned & "quoted"';

    Future<StepCommandResult> runIn(
      String text,
      AutomationShell shell, {
      Map<String, String> environment = const {},
    }) => commands.run(
      command(
        text,
        shell: shell,
        folder: EnvironmentPath(environmentId: 'local', path: folder.path),
      ),
      run,
      command: text,
      environment: environment,
      timeout: const Duration(minutes: 1),
    );

    test('PowerShell in a folder: its output, its exit code', () async {
      final result = await runIn(
        r'Write-Output (Get-Location).Path; exit 4',
        AutomationShell.powershell,
      );
      expect(result.exitCode, 4);
      expect(result.output.trim(), folder.path);
    }, skip: windows ? false : 'Windows only');

    test('cmd reads a hostile value with !NAME! and never runs it', () async {
      final result = await runIn(
        'echo !KARMASHALA_X!\nexit /b 0',
        AutomationShell.cmd,
        environment: stepEnvironment({'x': hostile}),
      );
      expect(result.exitCode, 0);
      expect(result.output.trim(), hostile);
      expect(
        folder.listSync().map((e) => e.path),
        isEmpty,
        reason: 'nothing the value said was run',
      );
    }, skip: windows ? false : 'Windows only');

    test('cmd: a failing line and its exit code', () async {
      final result = await runIn('echo nope\nexit /b 7', AutomationShell.cmd);
      expect(result.exitCode, 7);
      expect(result.output.trim(), 'nope');
    }, skip: windows ? false : 'Windows only');

    test('the login shell in a folder elsewhere', () async {
      final result = await runIn(
        r'pwd; printf "%s\n" "$KARMASHALA_X"; exit 5',
        AutomationShell.login,
        environment: stepEnvironment({'x': hostile}),
      );
      expect(result.exitCode, 5);
      expect(result.output, contains(hostile));
      expect(folder.listSync(), isEmpty);
    }, skip: windows ? 'not Windows' : false);
  });
}
