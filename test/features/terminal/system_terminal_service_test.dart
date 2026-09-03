import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';

/// The modes these command lines are built for, in each CLI's own vocabulary.
/// There is no shared enum left to name them with: "ask" is
/// `--permission-mode manual` to Claude Code, an unflagged run to Antigravity,
/// and a sandbox plus an approval policy to Codex.
final _claudeAsk = PermissionSelection.parse(claudeAskStored)!;
final _claudeAcceptEdits = PermissionSelection.parse(claudeAcceptEditsStored)!;
final _claudeBypass = PermissionSelection.parse(claudeBypassStored)!;
final _codexDefault = PermissionSelection.parse(codexDefaultStored)!;
final _codexBypass = PermissionSelection.parse(codexBypassStored)!;
final _antigravityAsk = PermissionSelection.parse(antigravityAskStored)!;
final _antigravityBypass = PermissionSelection.parse(antigravityBypassStored)!;
const _antigravityAcceptEdits = PermissionSelection({'mode': 'accept-edits'});

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
        permission: _claudeBypass,
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
        '--sandbox',
        'workspace-write',
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
      // wrong or may mean something else entirely; an agent the registry has never heard of
      // gets no arguments at all rather than another agent's flags
      // puts that on the wrong side of "safety by default".
      // Every real selection the three shipped CLIs have, plus "nothing
      // chosen": none of them may put a flag on a binary we have never read.
      for (final selection in [
        null,
        _claudeAsk,
        _claudeBypass,
        _codexDefault,
        _codexBypass,
        _antigravityAsk,
        _antigravityBypass,
      ]) {
        expect(
          permissionArgsFor('someAgentWeHaveNeverHeardOf', selection),
          isEmpty,
          reason: selection?.canonical ?? 'nothing chosen',
        );
      }
    });

    test('the built-in agents pass the flags their descriptors declare', () {
      // `ask` was `isEmpty` here until a real CLI contradicted it: an unflagged
      // Claude Code session starts in `auto` on a Pro/Max/Team account, so
      // passing nothing was not the safe mode it looked like.
      expect(permissionArgsFor('claudeCode', _claudeAsk), [
        '--permission-mode',
        'manual',
      ]);
      expect(permissionArgsFor('claudeCode', _claudeAcceptEdits), [
        '--permission-mode',
        'acceptEdits',
      ]);
      expect(permissionArgsFor('claudeCode', _claudeBypass), [
        '--permission-mode',
        'bypassPermissions',
      ]);

      // Codex has two axes and both reach the command line, sandbox first.
      // Not `on-failure` and no longer `untrusted`: codex-cli rejects both
      // outright and refuses to start (0.145.0 and 0.151.0 respectively). See
      // built_in_agents.dart for the transcripts.
      expect(permissionArgsFor('codex', _codexDefault), [
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'on-request',
      ]);
      // The bypass flag supersedes the approval axis, so it arrives alone.
      expect(permissionArgsFor('codex', _codexBypass), [
        '--dangerously-bypass-approvals-and-sandbox',
      ]);

      // Antigravity's `ask` is empty because prompting is what an unflagged
      // `agy` does — an exact mapping that needs no flag, not a mode we
      // cannot express. The other two are the flags `agy --help` documents;
      // `--yolo`, which this used to assert, is not a flag the CLI has.
      expect(permissionArgsFor('antigravity', _antigravityAsk), isEmpty);
      expect(permissionArgsFor('antigravity', _antigravityAcceptEdits), [
        '--mode',
        'accept-edits',
      ]);
      expect(permissionArgsFor('antigravity', _antigravityBypass), [
        '--dangerously-skip-permissions',
      ]);
    });
  });

  group('resume arguments come from the registry', () {
    // The bug: both builders chose their resume arguments with
    // `switch (cli) { 'claudeCode' => ['--resume', id], 'codex' => ['resume',
    // id], _ => [] }`, twenty lines under a `permissionArgsFor` that reads the
    // registry properly. Antigravity therefore got a command line with **no**
    // resume arguments — which does not fail, it silently starts a new
    // conversation wearing the old session's name.
    final cwd = EnvironmentPath(environmentId: 'windows', path: r'C:\ws\app');

    test('Antigravity resumes with the --conversation it declares', () {
      expect(
        resumeCommandLine(
          agentExecutable: 'agy',
          cli: 'antigravity',
          externalId: 'conv-1',
          environment: windowsEnv(),
          cwd: cwd,
        ),
        // `ask` is empty for `agy`: prompting is what an unflagged run does.
        ['agy', '--conversation', 'conv-1'],
      );
    });

    test('and carries it into the copied shell command too', () {
      expect(
        shellCommandLine(
          agentExecutable: 'agy',
          cli: 'antigravity',
          externalId: 'conv-1',
          permission: _antigravityAsk,
          cwd: r'C:\ws\app',
          environment: EnvironmentKind.windowsNative,
        ),
        r"Set-Location -LiteralPath 'C:\ws\app'; "
        r"& 'agy' '--conversation' 'conv-1'",
      );
    });

    test('an agent the registry never heard of gets no resume arguments', () {
      // Nothing is invented for it. The refusal that keeps such a command away
      // from the user lives in `SessionActions`, which can put the agent's name
      // in a sentence; here the only correct output is "no arguments".
      expect(
        resumeCommandLine(
          agentExecutable: 'mystery',
          cli: 'mysteryAgent',
          externalId: 'x',
          environment: windowsEnv(),
          cwd: cwd,
        ),
        ['mystery'],
      );
    });

    test('Claude Code and Codex keep the exact arguments they had', () {
      // Pinned: the point of reading the registry is that these two do not
      // move. Claude's flag comes before the id, Codex's is a subcommand, and
      // both sit after the permission flags. Only the *shell* around them
      // changed.
      expect(
        shellCommandLine(
          agentExecutable: 'claude',
          cli: 'claudeCode',
          externalId: 'abc',
          permission: _claudeAsk,
          cwd: '/home/me/app',
          environment: EnvironmentKind.wsl,
        ),
        'cd /home/me/app && claude --permission-mode manual --resume abc',
      );
      expect(
        shellCommandLine(
          agentExecutable: 'codex',
          cli: 'codex',
          externalId: 'sid',
          permission: _codexBypass,
          cwd: '/home/me/app',
          environment: EnvironmentKind.wsl,
        ),
        'cd /home/me/app && codex '
        '--dangerously-bypass-approvals-and-sandbox resume sid',
      );
    });

    test('a fresh-session command still names no conversation', () {
      expect(
        shellCommandLine(
          agentExecutable: 'agy',
          cli: 'antigravity',
          permission: _antigravityAsk,
          cwd: r'C:\ws\app',
          environment: EnvironmentKind.windowsNative,
        ),
        r"Set-Location -LiteralPath 'C:\ws\app'; & 'agy'",
      );
    });
  });

  group('the copied command is spelled for its own shell', () {
    // The owner's report: resuming a Windows-native Codex session offered a
    // command that "looks like a WSL command". It did — `shellCommandLine` had
    // no environment parameter at all and emitted `cd <cwd> && <parts>` for
    // every session in the app, Windows ones included.
    //
    // `&&` is not a PowerShell operator until PowerShell 7. Windows PowerShell
    // 5.1 — the shell a Windows box opens by default, and now the shell a
    // Windows-native pane launches — rejects the line outright, so the copied
    // command was broken for exactly the sessions it named Windows paths for.
    String lineFor(EnvironmentKind environment, String cwd) => shellCommandLine(
      agentExecutable: cwd.startsWith('/') ? 'codex' : r'C:\bin\codex.exe',
      cli: 'codex',
      externalId: 'sid',
      permission: _codexBypass,
      cwd: cwd,
      environment: environment,
    );

    test('a Windows-native session gets PowerShell, not `cd … &&`', () {
      final line = lineFor(
        EnvironmentKind.windowsNative,
        r'C:\Users\me\projects\personal\field-report',
      );
      expect(
        line,
        r"Set-Location -LiteralPath 'C:\Users\me\projects\personal\field-report'; "
        r"& 'C:\bin\codex.exe' "
        r"'--dangerously-bypass-approvals-and-sandbox' 'resume' 'sid'",
      );
      // The two halves of the defect, asserted separately so a regression names
      // itself: no `&&` (5.1 rejects it) and no bare `cd` (it is `Set-Location`
      // that takes `-LiteralPath`).
      expect(line, isNot(contains('&&')));
      expect(line, isNot(startsWith('cd ')));
    });

    test('WSL, SSH and a local POSIX host keep the sh form', () {
      for (final kind in [
        EnvironmentKind.wsl,
        EnvironmentKind.ssh,
        EnvironmentKind.localPosix,
      ]) {
        final line = lineFor(kind, '/home/me/app');
        expect(
          line,
          'cd /home/me/app && codex '
          '--dangerously-bypass-approvals-and-sandbox resume sid',
          reason: kind.name,
        );
        expect(line, isNot(contains('Set-Location')), reason: kind.name);
      }
    });

    test('a PowerShell path survives a space, an apostrophe and a \$', () {
      // Single quotes are PowerShell's literal string: nothing inside them
      // expands, so `$dev` stays text, and an embedded apostrophe is doubled
      // rather than escaped with a backslash. `mysteryAgent` is deliberate —
      // an agent the registry never heard of contributes no flags, so this
      // asserts quoting and nothing else.
      expect(
        shellCommandLine(
          agentExecutable: r"C:\Program Files\o'brien\codex.exe",
          cli: 'mysteryAgent',
          permission: _claudeAsk,
          cwd: r"C:\Users\me\$dev\it's here",
          environment: EnvironmentKind.windowsNative,
        ),
        r"Set-Location -LiteralPath 'C:\Users\me\$dev\it''s here'; "
        r"& 'C:\Program Files\o''brien\codex.exe'",
      );
    });

    test('a POSIX path with a backslash is quoted, not left bare', () {
      // A backslash escapes the next character in an unquoted `sh` word, so
      // leaving it bare would silently change the path. It used to be in the
      // "safe" set purely so Windows paths came out unquoted — which is how the
      // Windows line ended up looking like a WSL one in the first place.
      expect(
        shellCommandLine(
          agentExecutable: 'agent',
          cli: 'mysteryAgent',
          permission: _claudeAsk,
          cwd: r'/home/me/odd\dir',
          environment: EnvironmentKind.wsl,
        ),
        r"cd '/home/me/odd\dir' && agent",
      );
    });
  });

  group('resumeRefusalFor', () {
    test('says nothing for an agent that declares a convention', () {
      for (final cli in ['claudeCode', 'codex', 'antigravity']) {
        expect(
          resumeRefusalFor(AgentRegistry.builtIn, cli, 'ext-1'),
          isNull,
          reason: cli,
        );
      }
    });

    test('refuses in words for an agent that declares none', () {
      final refusal = resumeRefusalFor(
        AgentRegistry.builtIn,
        'mysteryAgent',
        'ext-1',
      );
      expect(refusal, isNotNull);
      expect(refusal, contains('mysteryAgent'));
      expect(refusal, contains('ext-1'));
      expect(refusal, contains('start a new'));
    });

    test('has nothing to refuse when no conversation is named', () {
      expect(resumeRefusalFor(AgentRegistry.builtIn, 'mysteryAgent', null), isNull);
      expect(resumeRefusalFor(AgentRegistry.builtIn, 'mysteryAgent', ''), isNull);
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
