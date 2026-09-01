import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  group('across hosts', _crossPlatformTests);

  group('resumeCommandLine', () {
    final cwd = EnvironmentPath(environmentId: 'windows', path: r'C:\ws\app');

    test('Claude on the Windows host resumes by id, in the asked mode', () {
      final cmd = resumeCommandLine(
        agentExecutable: 'claude',
        cli: 'claudeCode',
        externalId: 'abc',
        environment: windowsEnv(),
        cwd: cwd,
      );
      // `ask` used to add nothing here. It names `manual` now: an unflagged
      // Claude Code session starts in `auto` on a Pro/Max/Team account.
      expect(cmd, ['claude', '--permission-mode', 'manual', '--resume', 'abc']);
    });

    test('Claude bypass adds --permission-mode bypassPermissions', () {
      final cmd = resumeCommandLine(
        agentExecutable: 'claude',
        cli: 'claudeCode',
        externalId: 'abc',
        environment: windowsEnv(),
        cwd: cwd,
        permissionMode: PermissionMode.bypass,
      );
      expect(cmd, [
        'claude',
        '--permission-mode',
        'bypassPermissions',
        '--resume',
        'abc',
      ]);
    });

    test('a WSL session is wrapped in wsl.exe with --cd (codex ask flag)', () {
      final cmd = resumeCommandLine(
        agentExecutable: 'codex',
        cli: 'codex',
        externalId: 'sid',
        environment: wslEnv(distro: 'Ubuntu'),
        cwd: EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
      );
      expect(cmd, [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/me/app',
        '--',
        'codex',
        '--ask-for-approval',
        'on-request',
        'resume',
        'sid',
      ]);
    });
  });

  group('SystemTerminalService.launch', () {
    test('Windows Terminal opens at -d <cwd> and runs the command', () async {
      final runner = FakeCommandRunner();
      final service = SystemTerminalService(runner, windows: true, macOs: false);

      await service.launch(
        const SystemTerminal(
          kind: SystemTerminalKind.windowsTerminal,
          label: 'Windows Terminal',
          executable: 'wt.exe',
        ),
        command: ['claude', '--resume', 'abc'],
        workingDirectory: r'C:\ws\app',
      );

      expect(runner.startRequests.single.executable, 'wt.exe');
      expect(runner.startRequests.single.arguments, [
        '-w',
        '0',
        'new-tab',
        '-d',
        r'C:\ws\app',
        'claude',
        '--resume',
        'abc',
      ]);
    });

    test('available() returns terminals found on PATH', () async {
      final runner = FakeCommandRunner(
        responder: (req) => CommandResult(
          exitCode: req.arguments.first == 'wt.exe' ? 0 : 1,
          stdout: '',
          stderr: '',
        ),
      );
      final service = SystemTerminalService(runner, windows: true, macOs: false);

      final found = await service.available();
      expect(found.map((t) => t.executable), contains('wt.exe'));
      expect(found.map((t) => t.executable), isNot(contains('wezterm.exe')));
    });

    test(
      'PowerShell safely quotes executable, arguments, and working dir',
      () async {
        final runner = FakeCommandRunner();
        final service = SystemTerminalService(runner, windows: true, macOs: false);

        await service.launch(
          const SystemTerminal(
            kind: SystemTerminalKind.powerShell,
            label: 'PowerShell',
            executable: 'powershell.exe',
          ),
          command: [r'C:\Program Files\Claude\claude.exe', '--resume', 'a b'],
          workingDirectory: r"C:\work\owner's app",
        );

        expect(
          runner.startRequests.single.arguments.last,
          "Set-Location -LiteralPath 'C:\\work\\owner''s app'; "
          "& 'C:\\Program Files\\Claude\\claude.exe' '--resume' 'a b'",
        );
      },
    );
  });

  group('permissionArgsFor', () {
    test('an unrecognised agent never gets a guessed bypass flag', () {
      // Guessing any bypass flag for a binary we know nothing about may be
      // wrong or may mean something else entirely; PRODUCT.md principle 5
      // puts that on the wrong side of "safety by default".
      for (final mode in PermissionMode.values) {
        expect(
          permissionArgsFor('someAgentWeHaveNeverHeardOf', mode),
          isEmpty,
          reason: mode.name,
        );
      }
    });

    test('the built-in agents pass the flags their descriptors declare', () {
      // `ask` was `isEmpty` here until a real CLI contradicted it: an unflagged
      // Claude Code session starts in `auto` on a Pro/Max/Team account, so
      // passing nothing was not the safe mode it looked like.
      expect(permissionArgsFor('claudeCode', PermissionMode.ask), [
        '--permission-mode',
        'manual',
      ]);
      expect(permissionArgsFor('claudeCode', PermissionMode.acceptEdits), [
        '--permission-mode',
        'acceptEdits',
      ]);
      expect(permissionArgsFor('claudeCode', PermissionMode.bypass), [
        '--permission-mode',
        'bypassPermissions',
      ]);

      expect(permissionArgsFor('codex', PermissionMode.ask), [
        '--ask-for-approval',
        'on-request',
      ]);
      // Not `on-failure` and no longer `untrusted`: codex-cli rejects both
      // outright and refuses to start (0.145.0 and 0.151.0 respectively). See
      // built_in_agents.dart for the transcripts.
      expect(permissionArgsFor('codex', PermissionMode.acceptEdits), [
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'on-request',
      ]);
      expect(permissionArgsFor('codex', PermissionMode.bypass), [
        '--dangerously-bypass-approvals-and-sandbox',
      ]);

      // Antigravity's `ask` is empty because prompting is what an unflagged
      // `agy` does — an exact mapping that needs no flag, not a mode we
      // cannot express. The other two are the flags `agy --help` documents;
      // `--yolo`, which this used to assert, is not a flag the CLI has.
      expect(permissionArgsFor('antigravity', PermissionMode.ask), isEmpty);
      expect(permissionArgsFor('antigravity', PermissionMode.acceptEdits), [
        '--mode',
        'accept-edits',
      ]);
      expect(permissionArgsFor('antigravity', PermissionMode.bypass), [
        '--dangerously-skip-permissions',
      ]);
    });
  });
}

/// The host-shaped half. Every candidate used to be a `.exe` found with
/// `where.exe`, so on a Mac the external-terminal picker was empty and the
/// "Open in terminal" action had nothing to open.
void _crossPlatformTests() {
  test('a Mac is offered Mac terminals, not wt.exe', () {
    final candidates = SystemTerminalService.candidatesFor(
      windows: false,
      macOs: true,
    );

    expect(candidates.map((t) => t.label), contains('Terminal'));
    expect(candidates.map((t) => t.executable), isNot(contains('wt.exe')));
    expect(
      candidates.every((t) => !t.executable.endsWith('.exe')),
      isTrue,
      reason: 'nothing on a Mac is an .exe',
    );
  });

  test('Terminal.app is found where it lives, not on PATH', () {
    // It puts nothing on PATH, so a PATH-only search finds nothing on the one
    // platform where it is guaranteed to be installed.
    final terminal = SystemTerminalService.candidatesFor(
      windows: false,
      macOs: true,
    ).firstWhere((t) => t.kind == SystemTerminalKind.macTerminal);

    expect(
      terminal.appBundlePaths,
      contains('/System/Applications/Utilities/Terminal.app'),
    );
  });

  test('Linux is offered its own desktop terminals', () {
    final candidates = SystemTerminalService.candidatesFor(
      windows: false,
      macOs: false,
    );

    expect(candidates.map((t) => t.label), contains('GNOME Terminal'));
    expect(candidates.map((t) => t.label), isNot(contains('Terminal')));
  });

  test('a Windows host is unchanged', () {
    final candidates = SystemTerminalService.candidatesFor(
      windows: true,
      macOs: false,
    );

    expect(candidates.first.executable, 'wt.exe');
    expect(candidates.map((t) => t.kind), contains(SystemTerminalKind.cmd));
  });
}
