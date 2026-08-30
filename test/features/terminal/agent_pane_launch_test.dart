import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/sessions/application/session_launcher.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/terminal/data/pty_launch.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the PTY launch', () {
    test('a Windows-native agent runs directly', () {
      const launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: r'C:\bin\claude.exe',
        arguments: ['--permission-mode', 'acceptEdits'],
        workingDirectory: r'C:\repo',
      );
      expect(
        agentPtyLaunchFor(launch),
        const PtyLaunch(
          executable: r'C:\bin\claude.exe',
          arguments: ['--permission-mode', 'acceptEdits'],
          workingDirectory: r'C:\repo',
        ),
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
      expect(pty.executable, 'wsl.exe');
      expect(pty.arguments, [
        '-d',
        'Ubuntu',
        '--cd',
        '/home/u/repo',
        '--',
        '/home/u/.local/bin/claude',
        '--resume',
        'sid',
      ]);
      // wsl.exe sets the child's directory itself; the host process must not be
      // pointed at a Linux path it cannot resolve.
      expect(pty.workingDirectory, isNull);
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
      expect(env['WSLENV'], '$kSessionIdEnvironmentVariable/u');
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
      final pty = agentPtyLaunchFor(launch, onWindowsHost: false);
      expect(pty.executable, 'claude');
      expect(pty.workingDirectory, '/home/u/repo');
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

  group('interactive arguments come from the registry', () {
    final registry = AgentRegistry.builtIn;

    test('protocol base arguments are never used for a PTY launch', () {
      // `--output-format stream-json` on a TTY would put a machine protocol on
      // a human's screen — and Claude Code rejects it outside `--print` anyway.
      final args = agentPaneArguments(
        registry.byId(AgentIds.claudeCode),
        PermissionMode.ask,
      );
      expect(args, isNot(contains('stream-json')));
      expect(
        agentPaneArguments(registry.byId(AgentIds.codex), PermissionMode.ask),
        isNot(contains('app-server')),
      );
    });

    test('Claude Code is given the session id we chose', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          PermissionMode.acceptEdits,
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
        PermissionMode.ask,
        sessionId: 'ours',
        resumeSessionId: 'theirs',
      );
      expect(args, ['--resume', 'theirs']);
    });

    test('Codex resumes with a subcommand, after its global flags', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.codex),
          PermissionMode.bypass,
          resumeSessionId: 'sid',
        ),
        ['--dangerously-bypass-approvals-and-sandbox', 'resume', 'sid'],
      );
    });

    test('Codex is not offered a session id it cannot accept', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.codex),
          PermissionMode.ask,
          sessionId: 'uuid',
        ),
        ['--ask-for-approval', 'on-request'],
      );
    });

    test('the opening prompt is a positional argument where supported', () {
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.claudeCode),
          PermissionMode.ask,
          prompt: '  do the thing  ',
        ),
        ['do the thing'],
      );
    });

    test('an agent that has never been checked is launched bare', () {
      // Not handed a stray argument it might read as a subcommand, and not
      // handed another agent's permission flag.
      expect(
        agentPaneArguments(null, PermissionMode.bypass, prompt: 'hello'),
        isEmpty,
      );
      expect(
        agentPaneArguments(
          registry.byId(AgentIds.antigravity),
          PermissionMode.ask,
          prompt: 'hello',
        ),
        isEmpty,
      );
    });
  });
}
