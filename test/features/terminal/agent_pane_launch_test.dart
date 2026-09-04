import 'dart:convert';

import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_mcp_arguments.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/launch_context.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/permission_fixtures.dart';

/// The modes these launches run under, in each CLI's own vocabulary, read back
/// from the canonical strings a session row holds. There is no shared enum to
/// name them with any more: "ask" is `--permission-mode manual` to Claude Code,
/// an unflagged session to Antigravity, and a sandbox plus an approval policy
/// to Codex.
final _claudeAsk = PermissionSelection.parse(claudeAskStored)!;
final _claudeAcceptEdits = PermissionSelection.parse(claudeAcceptEditsStored)!;
final _claudeBypass = PermissionSelection.parse(claudeBypassStored)!;
final _codexDefault = PermissionSelection.parse(codexDefaultStored)!;
final _codexBypass = PermissionSelection.parse(codexBypassStored)!;
final _antigravityAsk = PermissionSelection.parse(antigravityAskStored)!;
const _antigravityAcceptEdits = PermissionSelection({'mode': 'accept-edits'});

/// Decodes what `powershell.exe -EncodedCommand` expects: base64 of UTF-16LE.
String decodePowerShellCommand(String encoded) {
  final bytes = base64Decode(encoded);
  final units = <int>[
    for (var i = 0; i + 1 < bytes.length; i += 2)
      bytes[i] | (bytes[i + 1] << 8),
  ];
  return String.fromCharCodes(units);
}

void main() {
  group('the PTY launch', () {
    test('a Windows-native agent goes through PowerShell, not directly', () {
      // The owner's rule: a Windows-native session resumes in PowerShell. It
      // still cannot be spawned directly — flutter_pty hands the child its own
      // executable name as its first argument and joins the rest with unquoted
      // spaces, which starts a turn about "codex.exe" and splits any argument
      // containing a space — so the whole script rides in one `-EncodedCommand`
      // token, which has nothing for that concatenation to split.
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: r'C:\bin\claude.exe',
        arguments: ['--permission-mode', 'acceptEdits', 'say hello'],
        workingDirectory: r'C:\repo',
      );
      final pty = agentPtyLaunchFor(launch);
      expect(pty.executable, 'powershell.exe');
      expect(pty.arguments.sublist(0, 3), [
        '-NoLogo',
        '-NoProfile',
        '-EncodedCommand',
      ]);
      expect(
        decodePowerShellCommand(pty.arguments.last),
        r"& 'C:\bin\claude.exe' '--permission-mode' 'acceptEdits' 'say hello'",
      );
      expect(pty.workingDirectory, r'C:\repo');
    });

    test('an executable path with a space is quoted', () {
      const launch = AgentPaneLaunch(
        agentId: 'x',
        executable: r'C:\Program Files\rover\rover.exe',
      );
      expect(
        decodePowerShellCommand(agentPtyLaunchFor(launch).arguments.last),
        r"& 'C:\Program Files\rover\rover.exe'",
      );
    });

    test('and a percent sign reaches the agent unsubstituted', () {
      // The hazard `cmd.exe` carried: it expands `%NAME%` while parsing and
      // quoting does not stop it, so a Windows-native prompt used to arrive
      // rewritten. PowerShell has no such parse step.
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: r'C:\bin\claude.exe',
        arguments: [r'explain %PATH% please'],
        workingDirectory: r'C:\repo',
      );
      expect(
        decodePowerShellCommand(agentPtyLaunchFor(launch).arguments.last),
        r"& 'C:\bin\claude.exe' 'explain %PATH% please'",
      );
    });

    test('a WSL agent is wrapped exactly as the external path wraps it', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: '/home/u/.local/bin/claude',
        arguments: ['--resume', 'sid'],
        workingDirectory: '/home/u/repo',
        wslDistribution: 'Ubuntu',
      );
      final pty = agentPtyLaunchFor(launch);
      // Through `cmd.exe /c`, like the shell pane. Spawned directly, the
      // duplicated leading token `flutter_pty` adds makes `wsl.exe` treat the
      // second `wsl.exe` as the command to run *inside* the distro, so the
      // login shell execs a Windows PE back out through `binfmt_misc` — which
      // dies as `MZ: command not found` the moment interop is unregistered.
      expect(pty.executable, 'cmd.exe');
      expect(
        pty.arguments.last,
        startsWith('wsl.exe -d Ubuntu --cd /home/u/repo -- eval '),
      );
      expect(
        _decodedScript(pty),
        "exec '/home/u/.local/bin/claude' '--resume' 'sid'",
      );
      // wsl.exe sets the child's directory itself; the host process must not be
      // pointed at a Linux path it cannot resolve.
      expect(pty.workingDirectory, isNull);
    });

    test('a WSL argument with a space stays one argument', () {
      // An unquoted prompt reached Claude Code as several arguments and was
      // silently ignored. The quoting that stops that is now POSIX quoting
      // inside the encoded payload, because the login shell — not `wsl.exe` —
      // is what splits the tail into arguments.
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        arguments: ['--permission-mode', 'acceptEdits', 'say hello there'],
        workingDirectory: '/home/u/repo',
        wslDistribution: 'Ubuntu',
      );
      expect(
        _decodedScript(agentPtyLaunchFor(launch)),
        "exec 'claude' '--permission-mode' 'acceptEdits' 'say hello there'",
      );
    });

    test('a prompt with a percent sign no longer needs the direct form', () {
      // `cmd` substitutes `%NAME%` while parsing and quoting does not stop it,
      // so this used to be sent the `wsl.exe wsl.exe …` interop round-trip to
      // keep `cmd` away from it — at the cost of dying whenever `binfmt_misc`
      // was unregistered. The percent sign is inside the base64 now, so there
      // is one WSL path again and it depends on nothing.
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        arguments: [r'explain %PATH% please'],
        workingDirectory: '/home/u/repo',
        wslDistribution: 'Ubuntu',
      );
      final pty = agentPtyLaunchFor(launch);
      expect(pty.executable, 'cmd.exe');
      expect(pty.arguments.last, isNot(contains('%')));
      expect(_decodedScript(pty), r"exec 'claude' 'explain %PATH% please'");
    });

    test('the session id reaches the agent through the environment', () {
      // Not as an argument: it has to reach a *grandchild*, the MCP bridge the
      // agent spawns, and an argument would not.
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        sessionId: 'sess-1',
      );
      expect(
        agentPtyLaunchFor(launch).environment[kSessionIdEnvironmentVariable],
        'sess-1',
      );
    });

    test('a WSL launch names the variable in WSLENV so it crosses over', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        wslDistribution: 'Ubuntu',
        sessionId: 'sess-1',
      );
      final env = agentPtyLaunchFor(launch).environment;
      expect(env[kSessionIdEnvironmentVariable], 'sess-1');
      // Both stamped variables cross, and `WSLENV` names both: the wrapper
      // builds it from whatever keys it was given, which is what makes adding
      // the port base a one-line change rather than a plumbing job.
      expect(
        env['WSLENV'],
        '$kSessionIdEnvironmentVariable/u:'
            '$kSessionPortBaseEnvironmentVariable/u',
      );
    });

    test('a session with no id sets no variables at all', () {
      const launch = AgentPaneLaunch(agentId: 'x', executable: 'x');
      expect(agentPtyLaunchFor(launch).environment, isEmpty);
    });

    test('a POSIX host does not wrap in wsl.exe', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        workingDirectory: '/home/u/repo',
        wslDistribution: 'Ubuntu',
      );
      final pty = agentPtyLaunchFor(
        launch,
        context: LaunchContext.forAgent(launch, hostIsWindows: false),
      );
      expect(pty.executable, 'claude');
      expect(pty.workingDirectory, '/home/u/repo');
    });
  });

  group('the command is built for the context it runs in', () {
    const wslLaunch = AgentPaneLaunch(
      agentId: 'claudeCode',
      executable: '/home/u/.local/bin/claude',
      arguments: ['--resume', 'sid'],
      workingDirectory: '/home/u/repo',
      wslDistribution: 'Ubuntu',
      sessionId: 'sess-1',
    );

    test('Windows host, WSL destination: wrapped in wsl.exe exactly once', () {
      final pty = agentPtyLaunchFor(
        wslLaunch,
        context: LaunchContext.forAgent(wslLaunch, hostIsWindows: true),
      );
      expect(pty.executable, 'cmd.exe');
      expect(
        pty.arguments.last,
        startsWith('wsl.exe -d Ubuntu --cd /home/u/repo -- eval '),
      );
      expect(
        _decodedScript(pty),
        "exec '/home/u/.local/bin/claude' '--resume' 'sid'",
      );
      // Once, still: the point of this test is that the destination is not
      // wrapped twice, and `cmd.exe /c` carries exactly one `wsl.exe`.
      expect(
        'wsl.exe'.allMatches(pty.arguments.join(' ')).length,
        1,
      );
    });

    test('Windows host, native destination: powershell.exe', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: r'C:\bin\claude.exe',
        arguments: ['--resume', 'sid'],
        workingDirectory: r'C:\repo',
      );
      final pty = agentPtyLaunchFor(
        launch,
        context: LaunchContext.forAgent(launch, hostIsWindows: true),
      );
      expect(pty.executable, 'powershell.exe');
      expect(
        decodePowerShellCommand(pty.arguments.last),
        r"& 'C:\bin\claude.exe' '--resume' 'sid'",
      );
      expect(pty.workingDirectory, r'C:\repo');
    });

    test('already inside WSL: no wsl.exe anywhere in the launch', () {
      // The owner's rule: if the session is being restored from a terminal that
      // is already in the distro, running `wsl.exe` again would nest a second
      // distro session inside the first.
      final context = LaunchContext.forAgent(wslLaunch, hostIsWindows: false);
      expect(context.kind, ShellContextKind.posix);
      expect(context.wslDistribution, 'Ubuntu');

      final pty = agentPtyLaunchFor(wslLaunch, context: context);
      expect(pty.executable, '/home/u/.local/bin/claude');
      expect(pty.arguments, ['--resume', 'sid']);
      expect(pty.workingDirectory, '/home/u/repo');
      expect(
        [pty.executable, ...pty.arguments].where((a) => a.contains('wsl.exe')),
        isEmpty,
      );
      // No WSLENV either: nothing is crossing a boundary, so the variables are
      // simply inherited.
      expect(pty.environment, {
        kSessionIdEnvironmentVariable: 'sess-1',
        kSessionPortBaseEnvironmentVariable: '${sessionPortBase('sess-1')}',
      });
    });

    test('a PowerShell destination uses the PowerShell form, not cmd.exe', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: r'C:\bin\claude.exe',
        arguments: ['say hello'],
        workingDirectory: r'C:\repo',
      );
      final pty = agentPtyLaunchFor(
        launch,
        context: const LaunchContext.powerShell(),
      );
      expect(pty.executable, 'powershell.exe');
      expect(pty.arguments.sublist(0, 3), [
        '-NoLogo',
        '-NoProfile',
        '-EncodedCommand',
      ]);
      expect(
        decodePowerShellCommand(pty.arguments.last),
        r"& 'C:\bin\claude.exe' 'say hello'",
      );
      expect(pty.workingDirectory, r'C:\repo');
    });

    test('a POSIX host with no distro runs the command as written', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: '/usr/bin/claude',
        arguments: ['--resume', 'sid'],
        workingDirectory: '/home/u/repo',
      );
      final context = LaunchContext.forAgent(launch, hostIsWindows: false);
      expect(context.kind, ShellContextKind.posix);
      final pty = agentPtyLaunchFor(launch, context: context);
      expect(pty.executable, '/usr/bin/claude');
      expect(pty.arguments, ['--resume', 'sid']);
      expect(pty.workingDirectory, '/home/u/repo');
    });

    test('wrapping is structurally single', () {
      // `wrapForPty` takes a ShellCommand and returns a PtyLaunch. The two are
      // unrelated types and nothing converts a PtyLaunch back into a
      // ShellCommand, so `wrapForPty(wrapForPty(...), ...)` does not compile —
      // a second wrapper is not a mistake this code can make.
      const command = ShellCommand(
        executable: 'claude',
        arguments: ['--resume', 'sid'],
        workingDirectory: '/home/u/repo',
      );
      final wrapped = wrapForPty(command, const LaunchContext.wsl('Ubuntu'));
      expect(wrapped, isA<PtyLaunch>());
      expect(wrapped, isNot(isA<ShellCommand>()));

      // And the external-terminal wrapper is single by the same construction.
      final external = wrapForExternalTerminal(
        command,
        const LaunchContext.wsl('Ubuntu'),
      );
      expect(external.take(7), [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/u/repo',
        '--',
        'eval',
      ]);
      expect(_decode(external.last), "exec 'claude' '--resume' 'sid'");
      expect(
        wrapForExternalTerminal(
          command,
          const LaunchContext.insideWsl('Ubuntu'),
        ),
        ['claude', '--resume', 'sid'],
      );
    });
  });

  group('Windows argument quoting', () {
    // CommandLineToArgvW's rules, because that is what the agent's own parser
    // applies on the other side.
    test('a value with no whitespace or quote is untouched', () {
      expect(quoteWindowsCommandArgument('--resume'), '--resume');
      expect(quoteWindowsCommandArgument(r'C:\repo\app'), r'C:\repo\app');
    });

    test('whitespace forces quoting', () {
      expect(quoteWindowsCommandArgument('say hello'), '"say hello"');
      expect(quoteWindowsCommandArgument('a\tb'), '"a\tb"');
    });

    test('an embedded quote is escaped', () {
      expect(quoteWindowsCommandArgument('say "hi"'), r'"say \"hi\""');
    });

    test('backslashes before a quote are doubled', () {
      expect(quoteWindowsCommandArgument(r'a\"b'), r'"a\\\"b"');
    });

    test('a trailing backslash cannot escape the closing quote', () {
      expect(
        quoteWindowsCommandArgument(r'C:\path with space\'),
        r'"C:\path with space\\"',
      );
    });

    test('an empty argument survives as an empty quoted string', () {
      expect(quoteWindowsCommandArgument(''), '""');
    });
  });

  group('the launch record survives a restart', () {
    test('it round-trips through JSON', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        arguments: ['--resume', 'sid'],
        workingDirectory: '/repo',
        wslDistribution: 'Ubuntu',
        sessionId: 's',
        title: 'Fix the build',
      );
      final back = AgentPaneLaunch.fromJson(launch.toJson())!;
      expect(agentPtyLaunchFor(back), agentPtyLaunchFor(launch));
      expect(back.title, 'Fix the build');
      expect(back.sessionId, 's');
    });

    test('an unreadable record is dropped, never thrown on', () {
      expect(AgentPaneLaunch.fromJson(null), isNull);
      expect(AgentPaneLaunch.fromJson('nonsense'), isNull);
      expect(AgentPaneLaunch.fromJson(<String, Object?>{}), isNull);
      expect(AgentPaneLaunch.fromJson({'agentId': 'x'}), isNull);
    });

    test('its profile id is deliberately not a shell profile', () {
      const launch = AgentPaneLaunch(agentId: 'claudeCode', executable: 'x');
      expect(launch.profileId, 'agent:claudeCode');
      expect(AgentPaneLaunch.isAgentProfileId(launch.profileId), isTrue);
      expect(AgentPaneLaunch.isAgentProfileId('powershell'), isFalse);
    });
  });

  /// The MCP flags name a config file deleted on every app start, a port
  /// rebound on every app start, and a credential minted fresh on every app
  /// start. Storing them made a restored pane replay all three, and the owner's
  /// agent refused to run:
  ///
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: `…/karmashala/mcp/session-<uuid>.json`
  group('the volatile MCP flags are never part of the record', () {
    test('a launch that ran with them is stored without them', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        arguments: ['--permission-mode', 'manual', '--resume', 'sid'],
        mcpArguments: [r'--mcp-config=C:\x\mcp\session-abc.json'],
        workingDirectory: '/repo',
        sessionId: 's',
      );
      final stored = jsonDecode(jsonEncode(launch.toJson())) as Map;

      expect(stored['arguments'], [
        '--permission-mode',
        'manual',
        '--resume',
        'sid',
      ]);
      expect(jsonEncode(stored), isNot(contains('mcp')));

      final back = AgentPaneLaunch.fromJson(stored)!;
      expect(back.mcpArguments, isEmpty);
      expect(back.commandArguments, [
        '--permission-mode',
        'manual',
        '--resume',
        'sid',
      ]);
    });

    test('what actually runs is the flags of now, then the stored intent', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        arguments: ['--permission-mode', 'manual', 'say hello'],
        mcpArguments: ['--mcp-config=/now.json'],
      );
      // MCP first: Codex's `-c` is a global option and its resume is a
      // subcommand, so everything global has to be on the left of it.
      expect(launch.commandArguments, [
        '--mcp-config=/now.json',
        '--permission-mode',
        'manual',
        'say hello',
      ]);
      expect(
        decodePowerShellCommand(agentPtyLaunchFor(launch).arguments.last),
        contains('--mcp-config=/now.json'),
      );
    });

    test('a record written before the fix is stripped on the way in', () {
      // The owner's saved layout holds rows in exactly this shape. Reading
      // one back has to drop the flag rather than replay it, or installing the
      // fix leaves every pane they already had just as broken.
      final back = AgentPaneLaunch.fromJson({
        'agentId': 'claudeCode',
        'executable': 'claude',
        'arguments': [
          r'--mcp-config=C:\Users\d\AppData\Roaming\com.popupbits'
              r'\karmashala\mcp\session-95659659.json',
          '--permission-mode',
          'acceptEdits',
          '--resume',
          'sid',
        ],
        'sessionId': 's',
      })!;

      expect(back.commandArguments, [
        '--permission-mode',
        'acceptEdits',
        '--resume',
        'sid',
      ]);
    });

    test("Codex's inline pair is stripped as a pair", () {
      // `-c <key>=<url>` is two tokens, and dropping only the value would leave
      // a dangling `-c` that takes the next argument as its own.
      final back = AgentPaneLaunch.fromJson({
        'agentId': 'codex',
        'executable': 'codex',
        'arguments': [
          '-c',
          'mcp_servers.karmashala.url=http://127.0.0.1:51234/mcp/dead-token',
          '--ask-for-approval',
          'on-request',
          'resume',
          'sid',
        ],
        'sessionId': 's',
      })!;

      expect(back.commandArguments, [
        '--ask-for-approval',
        'on-request',
        'resume',
        'sid',
      ]);
    });

    test('a `-c` that is not ours is left alone', () {
      // Codex takes `-c` for any config override; only the key we write is ours
      // to remove.
      final back = AgentPaneLaunch.fromJson({
        'agentId': 'codex',
        'executable': 'codex',
        'arguments': ['-c', 'model="gpt-5"', 'resume', 'sid'],
      })!;

      expect(back.commandArguments, ['-c', 'model="gpt-5"', 'resume', 'sid']);
    });
  });

  group('interactive arguments come from the registry', () {
    final registry = AgentRegistry.builtIn;

    test('a pane and an external terminal build the same command line', () {
      // "Open this in Windows Terminal instead" must produce the same agent, on
      // the same endpoint, speaking as the same session — and the pane now
      // assembles its line from two halves (durable arguments on the stored
      // record, volatile MCP flags rebuilt at each start) while the external
      // terminal still builds one list. This is what stops them drifting apart.
      const url = 'http://127.0.0.1:51234/mcp/tok';
      final descriptor = registry.byId(AgentIds.claudeCode);
      final external = agentPaneArguments(
        descriptor,
        _claudeAcceptEdits,
        sessionId: 'uuid',
        prompt: 'hello',
        mcpUrl: url,
        mcpConfigPath: '/c.json',
      );
      final pane = AgentPaneLaunch(
        agentId: AgentIds.claudeCode,
        executable: 'claude',
        arguments: agentPaneArguments(
          descriptor,
          _claudeAcceptEdits,
          sessionId: 'uuid',
          prompt: 'hello',
        ),
        mcpArguments: agentMcpArguments(
          descriptor,
          url: url,
          configPath: '/c.json',
        ),
      );
      expect(pane.commandArguments, external);
    });

    test('protocol base arguments are never used for a PTY launch', () {
      // `--output-format stream-json` on a TTY would put a machine protocol on
      // a human's screen — and Claude Code rejects it outside `--print` anyway.
      final args = agentPaneArguments(
        registry.byId(AgentIds.claudeCode),
        _claudeAsk,
      );
      expect(args, isNot(contains('stream-json')));
      expect(
        agentPaneArguments(registry.byId(AgentIds.codex), _codexDefault),
        isNot(contains('app-server')),
      );
    });

    test('Claude Code is given the session id we chose', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          _claudeAcceptEdits,
          sessionId: 'uuid-here',
        ),
        ['--permission-mode', 'acceptEdits', '--session-id', 'uuid-here'],
      );
    });

    test('resuming never also pins a session id', () {
      // `--session-id` and `--resume` are contradictory: one names a session to
      // create, the other one to continue.
      final args = agentPaneArguments(
        registry.byId(AgentIds.claudeCode),
        _claudeAsk,
        sessionId: 'ours',
        resumeSessionId: 'theirs',
      );
      expect(args, ['--permission-mode', 'manual', '--resume', 'theirs']);
    });

    test('Codex resumes with a subcommand, after its global flags', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.codex),
          _codexBypass,
          resumeSessionId: 'sid',
        ),
        ['--dangerously-bypass-approvals-and-sandbox', 'resume', 'sid'],
      );
    });

    test('Codex is not offered a session id it cannot accept', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.codex),
          _codexDefault,
          sessionId: 'uuid',
        ),
        ['--sandbox', 'workspace-write', '--ask-for-approval', 'on-request'],
      );
    });

    test('the opening prompt is a positional argument where supported', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          _claudeAsk,
          prompt: '  do the thing  ',
        ),
        ['--permission-mode', 'manual', 'do the thing'],
      );
      // Codex takes it the same way, and both lists are pinned here because
      // widening the model to carry a *flag* must not move the two CLIs that
      // were already right.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.codex),
          _codexDefault,
          prompt: '  do the thing  ',
        ),
        [
          '--sandbox',
          'workspace-write',
          '--ask-for-approval',
          'on-request',
          'do the thing',
        ],
      );
    });

    test('Antigravity takes its opening prompt behind a flag', () {
      // Two argv entries, not one: `agy` parses `--prompt-interactive` with
      // Go's flag package, which reads the value as the *next* argument.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.antigravity),
          _antigravityAsk,
          prompt: '  do the thing  ',
        ),
        ['--prompt-interactive', 'do the thing'],
      );
      // Beside the permission and resume flags rather than instead of them.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.antigravity),
          _antigravityAcceptEdits,
          resumeSessionId: 'c1',
          prompt: 'carry on',
        ),
        [
          '--mode',
          'accept-edits',
          '--conversation',
          'c1',
          '--prompt-interactive',
          'carry on',
        ],
      );
    });

    test('an Antigravity pane with no prompt gets neither flag nor value', () {
      // The flag is worthless without a value — `agy --prompt-interactive`
      // with nothing after it exits on `flag needs an argument: -i`.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.antigravity),
          _antigravityAsk,
        ),
        isEmpty,
      );
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.antigravity),
          _antigravityAsk,
          prompt: '   ',
        ),
        isEmpty,
      );
    });

    test('a prompt with spaces and quotes survives to the CLI', () {
      // The prompt stays **one** argv entry all the way down, and the quoting
      // that keeps it one is `quotePowerShellArgument`'s job — the same
      // guarantee Claude's positional prompt has always had. Asserted through
      // the real pane launch because that is where the two meet: the flag and
      // the value stay two tokens, not one joined pair.
      const prompt = 'say "hi" to a b';
      final launch = AgentPaneLaunch(
        agentId: AgentIds.antigravity,
        executable: 'agy',
        arguments: agentPaneArguments(
          registry.byId(AgentIds.antigravity),
          _antigravityAsk,
          prompt: prompt,
        ),
      );
      expect(launch.commandArguments, ['--prompt-interactive', prompt]);

      final pty = agentPtyLaunchFor(launch);
      expect(pty.executable, 'powershell.exe');
      expect(
        decodePowerShellCommand(pty.arguments.last),
        // PowerShell's literal string leaves the double quotes alone; only an
        // apostrophe would need doubling.
        '& \'agy\' \'--prompt-interactive\' \'say "hi" to a b\'',
      );
    });

    test('an agent that has never been checked is launched bare', () {
      // Not handed a stray argument it might read as a subcommand, and not
      // handed another agent's permission flag.
      expect(
        agentPaneArguments(null, _claudeBypass, prompt: 'hello'),
        isEmpty,
      );
    });
  });

  /// Being told where Karmashala's own tools are, in each agent's own words.
  ///
  /// Every claim here was read off a real `--help` or a real run; the point of
  /// the group is that an agent with no verified convention gets **nothing**,
  /// which is what the Antigravity descriptor got wrong for months.
  group('the MCP endpoint on the command line', () {
    const registry = AgentRegistry.builtIn;
    const url = 'http://172.18.240.1:51234/mcp/tok-en';
    const configPath = '/mnt/c/Users/d/AppData/Roaming/x/mcp/session-s1.json';

    test('Claude Code is pointed at a config file, in one token', () {
      // One token because `--mcp-config <configs...>` is variadic: given a
      // space, it eats the opening prompt below as a second config file.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          _claudeAsk,
          sessionId: 'uuid',
          prompt: 'do the thing',
          mcpUrl: url,
          mcpConfigPath: configPath,
        ),
        [
          '--mcp-config=$configPath',
          '--permission-mode',
          'manual',
          '--session-id',
          'uuid',
          'do the thing',
        ],
      );
    });

    test('Claude Code is never given --strict-mcp-config', () {
      // It would drop the user's own MCP servers for every session the app
      // opens. The default merges, which is the whole reason this is safe.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          _claudeAsk,
          mcpUrl: url,
          mcpConfigPath: configPath,
        ),
        isNot(contains('--strict-mcp-config')),
      );
    });

    test('Codex is given the URL inline, and no file', () {
      // Before its `resume` subcommand, because `-c` is a global option.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.codex),
          _codexDefault,
          resumeSessionId: 'sid',
          mcpUrl: url,
        ),
        [
          '-c',
          'mcp_servers.karmashala.url=$url',
          '--sandbox',
          'workspace-write',
          '--ask-for-approval',
          'on-request',
          'resume',
          'sid',
        ],
      );
    });

    test('Antigravity is given nothing, because nothing was verified', () {
      // `agy --help` names an `mcp` subcommand for editing its own config and
      // no launch option at all.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.antigravity),
          _antigravityAcceptEdits,
          mcpUrl: url,
          mcpConfigPath: configPath,
        ),
        ['--mode', 'accept-edits'],
      );
    });

    test('an agent nobody has checked is launched exactly as before', () {
      expect(
        agentPaneArguments(null, _claudeAsk, mcpUrl: url),
        isEmpty,
      );
    });

    test('no endpoint means no flag', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          _claudeAsk,
        ),
        isNot(contains(startsWith('--mcp-config'))),
      );
    });

    test('a config that could not be written means no flag either', () {
      // Not `--mcp-config=` with nothing after it: Claude would refuse to start
      // on a config file that is not there, so a launch that would have worked
      // would fail instead.
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          _claudeAsk,
          mcpUrl: url,
        ),
        ['--permission-mode', 'manual'],
      );
    });
  });

  group('sessionPortBase', () {
    /// cmux derives every shared resource in its own stack from one seed per
    /// workspace — `CMUX_PORT` gives the dev port, Postgres at `+10000`, the
    /// test database at `+30000`, the container and network names — because a
    /// worktree isolates files and nothing else. This is the small honest
    /// version of that, and what these tests hold it to is that it is
    /// *deterministic* and *in range*: it is a namespace, not a lock, and
    /// nothing here reserves anything.
    test('is stable for one id, so a resumed session keeps its number', () {
      expect(sessionPortBase('s-1'), sessionPortBase('s-1'));
    });

    test('is inside the window below both ephemeral ranges, and aligned', () {
      // Linux hands out ephemeral ports from 32768, Windows from 49152. A
      // derived port must never be one the OS may already have given away.
      for (final id in [
        's-1',
        's-2',
        '',
        'a-very-long-session-id-0123456789abcdef',
        '01a05160-2b15-7100-b99a-e38509bb4747',
      ]) {
        final base = sessionPortBase(id);
        expect(base, greaterThanOrEqualTo(kSessionPortBaseFloor));
        expect(base, lessThan(32768));
        expect(base % kSessionPortsPerSession, 0);
      }
    });

    test('spreads different ids across the slots', () {
      // Not a promise of uniqueness — see the doc comment, which puts ten
      // concurrent sessions at roughly a 3.5% chance of some collision. What is
      // asserted is that the derivation is not degenerate: a hundred ids must
      // not pile onto a handful of bases.
      final bases = {for (var i = 0; i < 100; i++) sessionPortBase('s-$i')};
      expect(bases.length, greaterThan(90));
    });

    test('does not depend on String.hashCode, which Dart does not promise is '
        'stable', () {
      // The value is written down. If the derivation ever changes, every
      // repository script keyed to a session's port changes under it, so the
      // change has to be deliberate enough to edit this line.
      expect(sessionPortBase('sess-1'), 29770);
    });
  });
}

/// The POSIX script a WSL launch really hands the distribution's login shell.
///
/// `wsl.exe … --` gives the shell the command line *tail*, so the payload is
/// base64 and what has to be asserted is what comes back out of it.
String _decodedScript(PtyLaunch launch) => _decode(launch.arguments.last);

String _decode(String text) {
  final match = RegExp(r"echo '([A-Za-z0-9+/=]+)'\|base64 -d").firstMatch(text);
  expect(match, isNotNull, reason: 'no encoded POSIX command in: $text');
  return utf8.decode(base64Decode(match!.group(1)!));
}
