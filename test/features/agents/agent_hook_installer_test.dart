import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/agents/data/agent_hook_installer.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const installer = AgentHookInstaller();
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_hookcfg_');
  });
  tearDown(() => home.deleteSync(recursive: true));

  File configFile() => File(p.join(home.path, 'settings.json'));

  Map<String, dynamic> hooks() {
    final json = jsonDecode(configFile().readAsStringSync()) as Map;
    return (json['hooks'] as Map).cast<String, dynamic>();
  }

  List<Map<String, dynamic>> commandsFor(String event) => [
    for (final matcher in hooks()[event] as List)
      for (final hook in (matcher as Map)['hooks'] as List)
        (hook as Map).cast<String, dynamic>(),
  ];

  test('creates the config with one entry per declared event', () async {
    final installed = await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.windowsNative,
    );

    expect(installed, isTrue);
    expect(hooks().keys.toSet(), claude.hooks!.eventStatus.keys.toSet());
    final stop = commandsFor('Stop').single;
    expect(stop['type'], 'command');
    expect(stop['command'], contains('127.0.0.1:4242/agent-hook'));
    expect(stop['command'], contains('agent=claudeCode'));
    expect(stop['command'], contains('event=Stop'));
    expect(stop['command'], contains('Bearer tok'));
    expect(stop['command'], contains(agentHookMarker));
  });

  test('leaves sibling keys byte-for-byte intact', () async {
    // Keys differing only by case are legal JSON that a decode/encode round
    // trip would collapse — the splice must not touch them.
    configFile().writeAsStringSync(
      '{"projects": {"g:/x": 1, "G:/x": 2}, "model": "opus"}',
    );

    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.windowsNative,
    );

    final raw = configFile().readAsStringSync();
    expect(raw, contains('"g:/x": 1'));
    expect(raw, contains('"G:/x": 2'));
    expect(raw, contains('"model": "opus"'));
  });

  test("keeps the user's own hooks for the same event", () async {
    configFile().writeAsStringSync(
      jsonEncode({
        'hooks': {
          'Stop': [
            {
              'hooks': [
                {'type': 'command', 'command': 'mine.sh'},
              ],
            },
          ],
        },
      }),
    );

    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.windowsNative,
    );

    final commands = commandsFor('Stop').map((h) => h['command']).toList();
    expect(commands, contains('mine.sh'));
    expect(commands.where((c) => '$c'.contains(agentHookMarker)), hasLength(1));
  });

  test('re-installing is idempotent', () async {
    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.windowsNative,
    );
    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: const AgentHookEndpoint(port: 5555, token: 'tok2'),
      environment: EnvironmentKind.windowsNative,
    );

    final commands = commandsFor('Stop');
    expect(commands, hasLength(1));
    // The rewritten command points at the new (ephemeral) port.
    expect(commands.single['command'], contains('127.0.0.1:5555'));
  });

  test('uninstall removes only our entries', () async {
    configFile().writeAsStringSync(
      jsonEncode({
        'hooks': {
          'Stop': [
            {
              'hooks': [
                {'type': 'command', 'command': 'mine.sh'},
              ],
            },
          ],
        },
        'model': 'opus',
      }),
    );
    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.windowsNative,
    );

    final removed = await installer.uninstall(
      descriptor: claude,
      storeHome: home.path,
    );

    expect(removed, isTrue);
    expect(commandsFor('Stop').map((h) => h['command']), ['mine.sh']);
    // Events we added and the user did not are dropped entirely.
    expect(hooks().containsKey('PreToolUse'), isFalse);
    expect(configFile().readAsStringSync(), contains('"model"'));
  });

  test('installing an endpoint already in the file rewrites nothing', () async {
    // The port is ephemeral, so a relaunch usually does change the command —
    // but when it does not, the file must be left exactly as the user's editor
    // left it. A no-op rewrite is still a write to somebody else's config.
    final indented = const JsonEncoder.withIndent('    ').convert({
      'hooks': {
        for (final event in claude.hooks!.eventStatus.keys)
          event: [
            {
              'hooks': [
                {
                  'type': 'command',
                  'command': installer.hookCommand(
                    descriptor: claude,
                    event: event,
                    endpoint: endpoint,
                    environment: EnvironmentKind.windowsNative,
                  ),
                },
              ],
            },
          ],
      },
    });
    configFile().writeAsStringSync(indented);

    final installed = await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.windowsNative,
    );

    expect(installed, isTrue);
    expect(configFile().readAsStringSync(), indented);
  });

  test(
    'a hook value that is not a list is left alone, not discarded',
    () async {
      // A hand-edited or future-shaped config. Install and uninstall have to
      // agree about it, and the only safe answer for both is "not mine".
      configFile().writeAsStringSync('{"hooks": {"Stop": "run-my-thing"}}');

      await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(hooks()['Stop'], 'run-my-thing');
      // Every other declared event still got its entry.
      expect(
        commandsFor('PreToolUse').single['command'],
        contains(agentHookMarker),
      );

      final removed = await installer.uninstall(
        descriptor: claude,
        storeHome: home.path,
      );

      expect(removed, isTrue);
      expect(hooks()['Stop'], 'run-my-thing');
      expect(configFile().readAsStringSync(), isNot(contains(agentHookMarker)));
    },
  );

  test('an agent with no hook spec installs nothing', () async {
    // Every shipped agent now declares hooks, so the case is exercised with a
    // descriptor that does not rather than dropped: an agent whose status comes
    // from somewhere else must not have a config file created for it.
    const hookless = AgentDescriptor(
      id: 'hookless',
      displayName: 'Hookless',
      binaries: AgentBinaries(windows: ['nope'], posix: ['nope']),
    );

    final installed = await installer.install(
      descriptor: hookless,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.windowsNative,
    );

    expect(installed, isFalse);
    expect(configFile().existsSync(), isFalse);
    expect(home.listSync(), isEmpty);
  });

  test('a malformed config is refused and left untouched', () async {
    configFile().writeAsStringSync('{ not json');

    await expectLater(
      installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(configFile().readAsStringSync(), '{ not json');
  });

  test('uninstall on a config we never touched is a no-op', () async {
    configFile().writeAsStringSync('{"model": "opus"}');

    final removed = await installer.uninstall(
      descriptor: claude,
      storeHome: home.path,
    );

    expect(removed, isFalse);
    expect(configFile().readAsStringSync(), '{"model": "opus"}');
  });

  group('the environment decides the address', () {
    const reachableWsl = AgentHookEndpoint(
      port: 4242,
      token: 'tok',
      wslHost: '172.18.240.1',
    );

    test('a WSL agent is given the switch address, not loopback', () async {
      final installed = await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: reachableWsl,
        environment: EnvironmentKind.wsl,
      );

      expect(installed, isTrue);
      final command = commandsFor('Stop').single['command'] as String;
      expect(command, contains('172.18.240.1:4242/agent-hook'));
      expect(
        command,
        isNot(contains('127.0.0.1')),
        reason:
            "127.0.0.1 inside a distribution is the distribution's own "
            'loopback, and a hook that cannot arrive is worse than one that '
            'was skipped — nothing reports the silence',
      );
    });

    test('an unreachable environment is refused, not written', () async {
      // A WSL host with no switch address and an SSH host are the same case:
      // nothing this app binds can be dialled from there.
      for (final (endpoint, kind) in [
        (const AgentHookEndpoint(port: 4242, token: 'tok'), EnvironmentKind.wsl),
        (reachableWsl, EnvironmentKind.ssh),
      ]) {
        final installed = await installer.install(
          descriptor: claude,
          storeHome: home.path,
          endpoint: endpoint,
          environment: kind,
        );

        expect(installed, isFalse, reason: '$kind');
        expect(
          configFile().existsSync(),
          isFalse,
          reason: 'a refused install must not so much as create the file',
        );
      }
    });

    test('hookCommand says so rather than spelling a dead URL', () {
      expect(
        installer.hookCommand(
          descriptor: claude,
          event: 'Stop',
          endpoint: const AgentHookEndpoint(port: 4242, token: 'tok'),
          environment: EnvironmentKind.wsl,
        ),
        isNull,
      );
    });

    test('the command survives the distribution\'s shell verbatim', () {
      // It is written into the agent's config and run by whatever `sh` the
      // distro has. Everything variable — the token and the whole URL — has to
      // sit inside double quotes with no character the shell would expand.
      final command = installer.hookCommand(
        descriptor: claude,
        event: 'Stop',
        endpoint: const AgentHookEndpoint(
          port: 4242,
          token: 'Ab-_9=',
          wslHost: '172.18.240.1',
        ),
        environment: EnvironmentKind.wsl,
      )!;

      expect(command, contains('"Authorization: Bearer Ab-_9="'));
      expect(
        command,
        contains(
          '"http://172.18.240.1:4242/agent-hook?agent=claudeCode&event=Stop'
          '&marker=$agentHookMarker"',
        ),
      );
      // `&` unquoted would background the curl; `$` and a backtick would
      // substitute. None of them may appear outside the two quoted spans.
      expect(command.split('"')[0], isNot(contains(RegExp(r'[&$`]'))));
      expect(command, isNot(contains(r'$')));
      expect(command, isNot(contains('`')));
      // It names no path of its own, so nothing in it has to be translated
      // between the Windows and the distribution filesystem.
      expect(command, isNot(contains(RegExp(r'[A-Za-z]:\\'))));
    });
  });

  group('a config the agent can still parse', () {
    test('a finished install leaves no scratch file behind', () async {
      configFile().writeAsStringSync('{"model": "opus"}');

      await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(
        home.listSync().map((e) => p.basename(e.path)).toList(),
        ['settings.json'],
      );
    });

    test('a replace that fails leaves the original whole', () async {
      // The new content is staged beside the config and moved onto it, so the
      // step that can fail is a rename and never a half-written settings.json.
      // Killed mid-install, the agent still starts.
      const original = '{"model": "opus", "hooks": {"Stop": []}}';
      configFile().writeAsStringSync(original);
      const failing = AgentHookInstaller(replace: _refuseToReplace);

      await expectLater(
        failing.install(
          descriptor: claude,
          storeHome: home.path,
          endpoint: endpoint,
          environment: EnvironmentKind.windowsNative,
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(configFile().readAsStringSync(), original);
      expect(jsonDecode(configFile().readAsStringSync()), isA<Map>());
      expect(
        home.listSync().map((e) => p.basename(e.path)).toList(),
        ['settings.json'],
        reason: 'the staged file is cleaned up even when the move fails',
      );
    });
  });

  group('the reported result is read back off the disk', () {
    test('a replace that lands nothing is not reported as installed', () async {
      // The bug this whole group exists for: `install` used to `return true`
      // straight after `_rewrite`, so *every* way a write can fail without
      // throwing was reported as a success that nobody would ever look into.
      configFile().writeAsStringSync('{"model": "opus"}');
      const silent = AgentHookInstaller(replace: _replaceButChangeNothing);

      final installed = await silent.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(installed, isFalse);
      expect(configFile().readAsStringSync(), '{"model": "opus"}');
    });

    test('a config rewritten behind us is not reported as installed', () async {
      // What actually happened on the owner's machine. Claude Code rewrites
      // `settings.json` from the copy it loaded at *its* startup, so an install
      // that landed at 11:25 was gone by 11:39 — and the app went on saying
      // "1 installed" because the claim was never checked against the file.
      await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );
      configFile().writeAsStringSync('{"model": "opus", "hooks": {}}');

      const silent = AgentHookInstaller(replace: _replaceButChangeNothing);
      final installed = await silent.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(installed, isFalse);
    });

    test('a real-world config keeps our marker through the splice', () async {
      // Shaped like the owner's own file: keys that differ only by case, an
      // escaped quote inside a permission string, a Windows path with
      // backslashes, and another tool's hooks already in the block. Every one
      // of those is something the byte-splice has to walk past, and the read
      // -back is what proves it did.
      configFile().writeAsStringSync(
        r'{"permissions": {"allow": ["Bash(node -e \":*)", '
        '"Read(//tmp/x/**)"], '
        r'"additionalDirectories": ["g:\\dev\\p\\.claude"]}, '
        '"projects": {"g:/x": 1, "G:/x": 2}, '
        '"hooks": {"Stop": [{"hooks": [{"type": "command", '
        '"command": "other-tool-hook"}]}]}, "model": "opus"}',
      );

      final installed = await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(installed, isTrue);
      final raw = configFile().readAsStringSync();
      expect(raw, contains('"g:/x": 1'));
      expect(raw, contains('"G:/x": 2'));
      expect(raw, contains(r'Bash(node -e \":*)'));
      expect(commandsFor('Stop').map((h) => h['command']), [
        'other-tool-hook',
        contains(agentHookMarker),
      ]);
      for (final event in claude.hooks!.eventStatus.keys) {
        expect(
          commandsFor(event).map((h) => h['command']),
          contains(contains(agentHookMarker)),
          reason: '$event should carry our callback',
        );
      }
    });
  });

  test('a hook that cannot deliver costs the agent nothing', () {
    // The owner watched `curl: (52) Empty reply from server` print into a live
    // Claude session, and the shell exit non-zero, because the app happened
    // not to be answering on the WSL interface. A status callback is this
    // app's business: it may lose an update, but it may not put a message in
    // someone else's terminal or fail their command.
    final command = AgentHookInstaller().hookCommand(
      descriptor: claude,
      event: 'Stop',
      endpoint: const AgentHookEndpoint(port: 4321, token: 'tok'),
      environment: EnvironmentKind.windowsNative,
    )!;

    expect(command, contains('curl -s '), reason: 'no error output');
    expect(command, isNot(contains('-sS')));
    expect(command, endsWith('|| true'), reason: 'no failing exit status');
    // And the third cost, which is the one a stale entry actually charges. The
    // port is ephemeral, so an entry outlives the app that could answer it —
    // and these hooks are *synchronous*: the CLI waits for this command before
    // it goes on. Unbounded, a dead port would stall the session the user is
    // typing into, on every tool call, for ever.
    expect(command, contains('-m 2'), reason: 'no unbounded wait');
  });
}

/// A replace step that never happens, standing in for the process dying between
/// staging the new config and moving it into place.
Future<void> _refuseToReplace(File staged, File destination) =>
    throw const FileSystemException('replace refused');

/// A replace step that reports success and moves nothing.
///
/// Stands in for every way a write can fail to land without raising: a config
/// the agent CLI rewrites from its own in-memory copy moments later, a
/// filesystem that swallows the move over a `\\wsl.localhost` share, a rename
/// onto a file another process holds open. The owner's machine showed the
/// symptom — `Agent hooks: 1 installed, 1 skipped` in the log, and not one
/// `karmashala-agent-hook` anywhere under `~/.claude` — and a reported install
/// that wrote nothing is worse than a reported skip, because the skip is the
/// only one of the two that ever gets investigated.
Future<void> _replaceButChangeNothing(File staged, File destination) async {}
