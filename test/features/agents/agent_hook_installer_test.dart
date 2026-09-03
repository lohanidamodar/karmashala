import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/agents/data/agent_hook_installer.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
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
  File endpointFile() => File(p.join(home.path, '$agentHookMarker.endpoint'));
  File windowsScript() => File(p.join(home.path, '$agentHookMarker.cmd'));

  /// What the config entry spells for a Windows-native Claude Code store — a
  /// constant, with no port and no token anywhere in it.
  const windowsCommand =
      'cmd.exe /c "%USERPROFILE%\\.claude\\$agentHookMarker.cmd"';

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
    expect(stop['command'], '$windowsCommand Stop');
    expect(stop['command'], contains(agentHookMarker));
    // Neither the port nor the token is in the agent's config any more. That
    // is the whole change: the entry is a constant, and the two things that
    // differ between launches are in the endpoint file the script reads when
    // the hook fires.
    expect(stop['command'], isNot(contains('4242')));
    expect(stop['command'], isNot(contains('tok')));

    final endpointText = endpointFile().readAsStringSync();
    expect(endpointText, contains('url=http://127.0.0.1:4242/agent-hook'));
    expect(endpointText, contains('agent=claudeCode'));
    expect(endpointText, contains('token=tok'));
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
    // The command is a constant, so the second launch found its own entry
    // already there and rewrote nothing. The new port went into the endpoint
    // file instead.
    expect(commands.single['command'], '$windowsCommand Stop');
    expect(endpointFile().readAsStringSync(), contains('127.0.0.1:5555'));
    expect(endpointFile().readAsStringSync(), contains('token=tok2'));
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

  test('an agent with hooks and no store gets no command', () async {
    // There is nowhere to keep the script and the endpoint file, so there is
    // no way to give this agent a command that does not change between
    // launches — and the inline form that used to fill that gap is the bug.
    // A refusal is the honest answer; every shipped agent declares a store.
    const homeless = AgentDescriptor(
      id: 'homeless',
      displayName: 'Homeless',
      binaries: AgentBinaries(windows: ['nope'], posix: ['nope']),
      hooks: AgentHookSpec(
        configFileName: 'settings.json',
        eventStatus: {'Stop': AgentActivityStatus.idle},
      ),
    );

    expect(
      installer.hookCommand(
        descriptor: homeless,
        event: 'Stop',
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      ),
      isNull,
    );
    expect(
      await installer.install(
        descriptor: homeless,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      ),
      isFalse,
    );
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

  group('the environment decides the transport', () {
    test('a WSL agent is given a spool directory, not an address', () async {
      final installed = await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.wsl,
      );

      expect(installed, isTrue);
      // The command names a path, not an address — and now neither does the
      // endpoint file beside it. `127.0.0.1` inside a distribution is that
      // distribution's own loopback, and the switch address that used to go
      // here accepted a connection and reset the first byte after it.
      final command = commandsFor('Stop').single['command'] as String;
      expect(command, 'sh "\$HOME/.claude/$agentHookMarker.sh" Stop');
      final endpointText = endpointFile().readAsStringSync();
      expect(endpointText, contains('spool=$agentHookMarker.spool'));
      expect(endpointText, contains('agent=claudeCode'));
      expect(endpointText, isNot(contains('127.0.0.1')));
      expect(endpointText, isNot(contains('http')));
      expect(
        Directory(p.join(home.path, '$agentHookMarker.spool')).existsSync(),
        isTrue,
        reason:
            'written before the endpoint file that names it: the script exits '
            'zero on a directory that is not there, so a half-finished '
            'install costs the agent nothing',
      );
    });

    test('no token is written where nothing crosses a network', () async {
      // Not an omission. A bearer token proves to a *receiver* that the sender
      // is not a stranger who bound the port; there is no port here and no
      // stranger who could bind one, so carrying one would put a credential at
      // rest inside somebody's distribution to authenticate nothing.
      await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: const AgentHookEndpoint(port: 4242, token: 'S3CRET-token'),
        environment: EnvironmentKind.wsl,
      );

      final endpointText = endpointFile().readAsStringSync();
      expect(endpointText, isNot(contains('S3CRET-token')));
      expect(endpointText, isNot(contains('token=')));
    });

    test('an SSH environment is refused, not written', () async {
      // Another machine: it shares neither a loopback nor a filesystem with
      // this process, so nothing it could be told would be true.
      final installed = await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.ssh,
      );

      expect(installed, isFalse);
      expect(
        configFile().existsSync(),
        isFalse,
        reason: 'a refused install must not so much as create the file',
      );
    });

    test('hookCommand says so rather than spelling a dead command', () {
      expect(
        installer.hookCommand(
          descriptor: claude,
          event: 'Stop',
          endpoint: endpoint,
          environment: EnvironmentKind.ssh,
        ),
        isNull,
      );
    });

    test('the spool branch writes whole payloads, and only whole ones', () async {
      // Three properties of four lines of `sh` that a live run proves and a
      // string cannot — but that a string can stop somebody undoing.
      // `live_wsl_hook_test.dart` runs this against a real distribution.
      await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.wsl,
      );
      final script = File(
        p.join(home.path, '$agentHookMarker.sh'),
      ).readAsStringSync();

      // 1. The event is saved before the cap re-uses `$@`. Without this the
      //    payload is stamped with a glob of the spool directory, which is how
      //    the first draft of this failed.
      expect(
        script.indexOf('event="\$1"'),
        lessThan(script.indexOf(r'set -- "$dir"/*.json')),
      );
      // 2. Written as `.part` and renamed, so a reader on the other side of a
      //    9p share never sees half a payload — the rename is what makes a
      //    `.json` mean "whole".
      expect(script, contains(r'> "$dir/$$-$n.part"'));
      expect(script, contains(r'mv -f "$dir/$$-$n.part" "$dir/$$-$n.json"'));
      // 3. Bounded, so an app that died without deleting the directory cannot
      //    have it grow without limit while it is gone.
      expect(script, contains(r'[ "$#" -lt 2000 ] || exit 0'));
      // And it exits zero on a directory that is not there: that is what
      // retiring the spool on the way out costs the agent.
      expect(script, contains(r'[ -d "$dir" ] || exit 0'));
    });

    test('the command survives the distribution\'s shell verbatim', () {
      // It is written into the agent's config and run by whatever `sh` the
      // distro has. Everything variable — the token and the whole URL — has to
      // sit inside double quotes with no character the shell would expand.
      final command = installer.hookCommand(
        descriptor: claude,
        event: 'Stop',
        endpoint: const AgentHookEndpoint(port: 4242, token: 'Ab-_9='),
        environment: EnvironmentKind.wsl,
      )!;

      expect(command, 'sh "\$HOME/.claude/$agentHookMarker.sh" Stop');
      // `&` unquoted would background the command and a backtick would
      // substitute; neither appears at all now that no URL is in it.
      expect(command, isNot(contains('&')));
      expect(command, isNot(contains('`')));
      // The one `\$` is `\$HOME`, inside the quoted span the shell must expand
      // — the app reaches that store over a UNC name the distro cannot open.
      expect(command.split('"')[0], isNot(contains(RegExp(r'[&$`]'))));
      // It names no *Windows* path, so nothing in it has to be translated
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
        home.listSync().map((e) => p.basename(e.path)).toSet(),
        {
          'settings.json',
          '$agentHookMarker.cmd',
          '$agentHookMarker.endpoint',
        },
        reason: 'the two generated files, and no staged temporary beside them',
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
        home.listSync().where((e) => e.path.endsWith('.karmashala-tmp')),
        isEmpty,
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

  test('a hook that cannot deliver costs the agent nothing', () async {
    // The owner watched `curl: (52) Empty reply from server` print into a live
    // Claude session, and the shell exit non-zero, because the app happened
    // not to be answering on the WSL interface. A status callback is this
    // app's business: it may lose an update, but it may not put a message in
    // someone else's terminal or fail their command. Those properties moved
    // into the generated script when the command stopped being a curl; they
    // did not stop being the point.
    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: const AgentHookEndpoint(port: 4321, token: 'tok'),
      environment: EnvironmentKind.windowsNative,
    );
    final script = windowsScript().readAsStringSync();

    expect(script, contains('curl -s '), reason: 'no error output');
    expect(script, isNot(contains('-sS')));
    expect(script.trimRight(), endsWith('exit /b 0'), reason: 'never fails');
    // These hooks are *synchronous*: the CLI waits for this before it goes on.
    // Unbounded, a dead port would stall the session the user is typing into,
    // on every tool call.
    expect(script, contains('-m 2'), reason: 'no unbounded wait');
    // And the cost a stale install now charges, which is the one that changed.
    // With the endpoint file retired on the way out there is no dial at all —
    // one `if not exist` and the script is done.
    expect(script, contains('if not exist "%KS_ENDPOINT%" exit /b 0'));
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
