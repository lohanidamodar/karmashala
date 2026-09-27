import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show CliStore;
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_host/src/hooks/hook_spools.dart';
import 'package:karmashala_host_protocol/protocol.dart' show AgentHookEvent;
import 'package:test/test.dart';

/// Slice 5a: the WSL agents' hook spools are drained by the server itself —
/// listed by name over the share, read from inside the distribution over
/// `wsl.exe`, and handed to the same intake as a hook on the loopback
/// endpoint. No `wsl.exe` is started here: every command is answered.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);
  const unc = r'\\wsl.localhost\Ubuntu\home\u\.claude';

  ExecutionEnvironment env(String id, EnvironmentKind kind, {String? distro}) =>
      ExecutionEnvironment(
        id: id,
        kind: kind,
        name: id,
        wslDistribution: distro,
        createdAt: t0,
      );

  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  final spoolDir = const AgentHookInstaller().spoolDirectoryFor(claude, unc)!;

  group('wslHookSpoolSources', () {
    test('one spool per hook-taking agent with a store in a distribution; '
        'none for this machine', () {
      final sources = wslHookSpoolSources(
        stores: const [
          CliStore(
            environmentId: 'wsl1',
            homesByAgentId: {AgentIds.claudeCode: unc},
          ),
          CliStore(
            environmentId: 'local',
            homesByAgentId: {AgentIds.claudeCode: '/Users/u/.claude'},
          ),
        ],
        environments: [
          env('wsl1', EnvironmentKind.wsl, distro: 'Ubuntu'),
          env('local', EnvironmentKind.localPosix),
        ],
      );
      expect(sources, [
        HookSpoolSource(
          environmentId: 'wsl1',
          distribution: 'Ubuntu',
          directory: spoolDir.path,
        ),
      ]);
      expect(sources.single.linuxDirectory, startsWith('/home/u/.claude/'));
    });
  });

  group('HookSpools', () {
    late List<CommandRequest> ran;
    late List<AgentHookEvent> taken;
    late Set<String> running;
    late String drained;
    late bool payloads;

    setUp(() {
      ran = [];
      taken = [];
      running = {'Ubuntu'};
      payloads = true;
      drained = '';
    });

    String record(String name, String header, String body) =>
        '$name\n${t0.millisecondsSinceEpoch ~/ 1000}\n$header\n\n$body\u0000';

    HookSpools spools() => HookSpools(
      sources: () async => [
        HookSpoolSource(
          environmentId: 'wsl1',
          distribution: 'Ubuntu',
          directory: spoolDir.path,
        ),
      ],
      onHook: taken.add,
      hasPayloads: (_) async => payloads,
      run: (request) async {
        ran.add(request);
        if (request.arguments.contains('--running')) {
          // wsl.exe answers in UTF-16 on a real machine; plain here.
          return CommandResult(
            exitCode: 0,
            stdout: running.join('\n'),
            stderr: '',
          );
        }
        return CommandResult(exitCode: 0, stdout: drained, stderr: '');
      },
    );

    test('a payload is read inside its distribution and taken as a hook, '
        'with its pane\'s session and its own time', () async {
      drained = record(
        '1.json',
        'agent=${AgentIds.claudeCode}\nevent=Stop\nsession=row-1',
        '{"session_id":"c1"}',
      );
      await spools().drainOnce();
      final drain = ran.last;
      expect(drain.executable, 'wsl.exe');
      expect(drain.arguments.take(3), ['-d', 'Ubuntu', '--exec']);
      expect(
        drain.arguments[drain.arguments.length - 2],
        startsWith('/home/u/.claude/'),
      );
      final hook = taken.single;
      expect(hook.agent, AgentIds.claudeCode);
      expect(hook.event, 'Stop');
      expect(hook.sessionHeader, 'row-1');
      expect(hook.receivedAt, t0);
      expect(hook.body, {'session_id': 'c1'});
    });

    test('a stopped distribution is neither woken nor drained', () async {
      running = {'Debian'};
      drained = record('1.json', 'agent=x\nevent=Stop', '{}');
      await spools().drainOnce();
      expect(ran.map((r) => r.arguments.first), ['-l']);
      expect(taken, isEmpty);
    });

    test(
      'a spool whose names show no payload costs no wsl.exe drain',
      () async {
        payloads = false;
        await spools().drainOnce();
        expect(ran.where((r) => r.arguments.contains('--exec')), isEmpty);
      },
    );

    test('a payload that is not a JSON object is dropped, as the endpoint '
        'drops it', () async {
      drained =
          record('1.json', 'agent=a\nevent=Stop', 'not json') +
          record('2.json', 'agent=a\nevent=Stop', '[1]') +
          record('3.json', 'agent=a\nevent=Stop', '{"ok":true}');
      await spools().drainOnce();
      expect(taken.map((h) => h.body), [
        {'ok': true},
      ]);
    });

    test('closed, it drains nothing more', () async {
      drained = record('1.json', 'agent=a\nevent=Stop', '{}');
      final s = spools()..close();
      await s.drainOnce();
      expect(ran, isEmpty);
      expect(taken, isEmpty);
    });
  });
}
