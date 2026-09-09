import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/agents/data/agent_hook_installer.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// The endpoint-file indirection, for **all three** shipped agents.
///
/// The per-agent files beside this one cover each CLI's own config shape. This
/// one covers the property they share and the reason it exists: the string this
/// app writes into somebody else's global configuration must be the same string
/// on every launch, so it can be written once and then left alone. Until Loop 71
/// it carried an ephemeral port and a per-run bearer token, so it changed twice
/// per app lifetime — and on the owner's machine the entry was simply gone,
/// zero occurrences under `~/.claude`, while a competitor's hooks written three
/// months earlier were still firing off an unchanging command.
///
/// Nothing here runs an agent CLI. The shell cases at the bottom run the
/// **generated script** against a fake listener, which is the only way to
/// establish what it does when the port it was told about belongs to somebody
/// else.
void main() {
  const installer = AgentHookInstaller();
  final agents = [
    for (final descriptor in AgentRegistry.builtIn.descriptors)
      if (descriptor.hooks != null) descriptor,
  ];

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_endpointfile_');
  });
  tearDown(() => removeTempDirectory(home));

  /// The store home the locator would hand the installer:
  /// `<home>/<store.homeDirectoryName>` and nothing else — see
  /// `CliStoreLocator._homesUnder`, which is what makes the `%USERPROFILE%` /
  /// `$HOME` in the generated command name this very directory at run time.
  String storeHomeOf(AgentDescriptor descriptor) {
    final dir = Directory(
      p.joinAll([home.path, ...p.posix.split(descriptor.store!.homeDirectoryName)]),
    )..createSync(recursive: true);
    return dir.path;
  }

  File configOf(AgentDescriptor descriptor) =>
      installer.configFileFor(descriptor, storeHomeOf(descriptor))!;

  File endpointOf(AgentDescriptor descriptor) =>
      File(p.join(storeHomeOf(descriptor), '$agentHookMarker.endpoint'));

  File scriptOf(AgentDescriptor descriptor, EnvironmentKind environment) => File(
    p.join(
      storeHomeOf(descriptor),
      environment == EnvironmentKind.windowsNative
          ? '$agentHookMarker.cmd'
          : '$agentHookMarker.sh',
    ),
  );

  /// Two launches of the same app: different ephemeral port, different token.
  const first = AgentHookEndpoint(
    port: 47821,
    token: 'AAAAtokenFromLaunchOne',
  );
  const second = AgentHookEndpoint(
    port: 51099,
    token: 'BBBBtokenFromLaunchTwo',
  );

  const environments = [
    EnvironmentKind.windowsNative,
    EnvironmentKind.localPosix,
    EnvironmentKind.wsl,
  ];

  group('the command written into the config is a constant', () {
    for (final descriptor in agents) {
      for (final environment in environments) {
        test('${descriptor.id} in ${environment.name}', () {
          String commandWith(AgentHookEndpoint endpoint) => installer.hookCommand(
            descriptor: descriptor,
            event: 'Stop',
            endpoint: endpoint,
            environment: environment,
          )!;

          // The headline. Two launches that agree about neither the port nor
          // the token write the same bytes into the user's file — and so does
          // a launch that changed the WSL agent's *transport* entirely, which
          // is what made moving WSL off the network affordable at all.
          expect(commandWith(first), commandWith(second));
          for (final endpoint in [first, second]) {
            final command = commandWith(endpoint);
            expect(command, isNot(contains('${endpoint.port}')));
            expect(command, isNot(contains(endpoint.token)));
            expect(command, contains(agentHookMarker));
          }
        });
      }
    }

    test('and installing twice leaves every config byte-identical', () async {
      for (final descriptor in agents) {
        await installer.install(
          descriptor: descriptor,
          storeHome: storeHomeOf(descriptor),
          endpoint: first,
          environment: EnvironmentKind.windowsNative,
        );
      }
      final afterFirst = {
        for (final descriptor in agents)
          descriptor.id: configOf(descriptor).readAsStringSync(),
      };

      for (final descriptor in agents) {
        expect(
          await installer.install(
            descriptor: descriptor,
            storeHome: storeHomeOf(descriptor),
            endpoint: second,
            environment: EnvironmentKind.windowsNative,
          ),
          isTrue,
          reason: descriptor.id,
        );
      }

      for (final descriptor in agents) {
        expect(
          configOf(descriptor).readAsStringSync(),
          afterFirst[descriptor.id],
          reason:
              '${descriptor.id}: the second launch must not rewrite the '
              "user's config at all",
        );
        // The new launch's address and token went into the one file that is
        // ours, and the old ones are not in it any more.
        final endpointText = endpointOf(descriptor).readAsStringSync();
        expect(endpointText, contains('127.0.0.1:${second.port}'));
        expect(endpointText, contains('token=${second.token}'));
        expect(endpointText, isNot(contains('${first.port}')));
        expect(endpointText, isNot(contains(first.token)));
      }
    });
  });

  group("somebody else's entry survives install, uninstall and reinstall", () {
    /// Shaped like the residue actually on the owner's machine: Orca's hook
    /// entries, written on 22 June and still firing. Claude Code and Codex
    /// share one `hooks` object, so the collision is per-event and inside a
    /// list; Antigravity's file is a map of hook *names*, so theirs is a
    /// sibling key at the root. Losing either would be unforgivable.
    String theirs(AgentDescriptor descriptor) {
      final spec = descriptor.hooks!;
      if (spec.configKey != 'hooks') {
        return const JsonEncoder.withIndent('  ').convert({
          'orca-status': {
            'Stop': [
              {'type': 'command', 'command': 'orca-hook.cmd Stop'},
            ],
          },
        });
      }
      return const JsonEncoder.withIndent('  ').convert({
        'description': 'my own hooks',
        'hooks': {
          'Stop': [
            {
              'matcher': 'shell',
              'hooks': [
                {'type': 'command', 'command': 'orca-hook.sh', 'timeout': 5},
              ],
            },
          ],
        },
        'model': 'opus',
      });
    }

    /// Their half of the file, decoded. For the two agents that share a `hooks`
    /// object with us it is the event list they wrote; for Antigravity, whose
    /// file is keyed by hook name, it is their whole sibling key — which the
    /// splice never touches at all.
    Object? theirHalf(AgentDescriptor descriptor, String raw) {
      final root = jsonDecode(raw) as Map<String, Object?>;
      if (descriptor.hooks!.configKey != 'hooks') return root['orca-status'];
      final hooks = root['hooks']! as Map<String, Object?>;
      return [
        for (final group in hooks['Stop']! as List)
          if (!jsonEncode(group).contains(agentHookMarker)) group,
      ];
    }

    /// Bytes elsewhere in the file that a decode/encode round trip would have
    /// reformatted, so "their key survived" is a claim about the file and not
    /// about an equivalent object.
    List<String> untouchedBytes(AgentDescriptor descriptor) =>
        descriptor.hooks!.configKey != 'hooks'
        ? const ['"orca-status": {', '"command": "orca-hook.cmd Stop"']
        : const ['"description": "my own hooks"', '"model": "opus"'];

    for (final descriptor in agents) {
      test(descriptor.id, () async {
        final config = configOf(descriptor)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(theirs(descriptor));
        final before = theirHalf(descriptor, theirs(descriptor));

        await installer.install(
          descriptor: descriptor,
          storeHome: storeHomeOf(descriptor),
          endpoint: first,
          environment: EnvironmentKind.localPosix,
        );
        expect(config.readAsStringSync(), contains('orca-hook'));
        expect(theirHalf(descriptor, config.readAsStringSync()), before);

        await installer.uninstall(
          descriptor: descriptor,
          storeHome: storeHomeOf(descriptor),
        );
        final afterUninstall = config.readAsStringSync();
        expect(afterUninstall, isNot(contains(agentHookMarker)));
        expect(theirHalf(descriptor, afterUninstall), before);
        for (final bytes in untouchedBytes(descriptor)) {
          expect(afterUninstall, contains(bytes), reason: descriptor.id);
        }

        await installer.install(
          descriptor: descriptor,
          storeHome: storeHomeOf(descriptor),
          endpoint: second,
          environment: EnvironmentKind.localPosix,
        );
        final after = config.readAsStringSync();
        expect(theirHalf(descriptor, after), before);
        expect(after, contains(agentHookMarker));
        for (final bytes in untouchedBytes(descriptor)) {
          expect(after, contains(bytes), reason: descriptor.id);
        }
      });
    }
  });

  group('uninstall leaves nothing behind', () {
    for (final descriptor in agents) {
      test(descriptor.id, () async {
        await installer.install(
          descriptor: descriptor,
          storeHome: storeHomeOf(descriptor),
          endpoint: first,
          environment: EnvironmentKind.localPosix,
        );
        expect(scriptOf(descriptor, EnvironmentKind.localPosix).existsSync(), isTrue);
        expect(endpointOf(descriptor).existsSync(), isTrue);

        final removed = await installer.uninstall(
          descriptor: descriptor,
          storeHome: storeHomeOf(descriptor),
        );

        expect(removed, isTrue);
        expect(
          scriptOf(descriptor, EnvironmentKind.localPosix).existsSync(),
          isFalse,
        );
        expect(endpointOf(descriptor).existsSync(), isFalse);
        // And nothing left under the store home names the port or the token.
        for (final entity in Directory(storeHomeOf(descriptor)).listSync()) {
          if (entity is! File) continue;
          final text = entity.readAsStringSync();
          expect(text, isNot(contains('${first.port}')), reason: entity.path);
          expect(text, isNot(contains(first.token)), reason: entity.path);
        }
      });
    }
  });

  group('the endpoint file is closed to other accounts where it can be', () {
    /// Records what the installer asked to restrict, without spawning `icacls`
    /// or `chmod` — the real tools cannot be made to answer on demand, and the
    /// question here is whether the *staged* file is hardened before the token
    /// reaches it.
    final asked = <(String, EnvironmentKind)>[];
    final tracked = AgentHookInstaller(
      restrict: (file, environment) async {
        asked.add((file.path, environment));
        // The token must not be in it yet.
        expect(file.readAsStringSync(), isEmpty);
        return true;
      },
    );
    setUp(asked.clear);

    test('the staged endpoint file is hardened before it holds a token', () async {
      final claude = agents.firstWhere((a) => a.id == 'claudeCode');

      await tracked.install(
        descriptor: claude,
        storeHome: storeHomeOf(claude),
        endpoint: first,
        environment: EnvironmentKind.localPosix,
      );

      expect(asked, hasLength(1));
      expect(asked.single.$1, endsWith('.karmashala-tmp'));
      expect(asked.single.$1, contains(agentHookMarker));
      expect(asked.single.$2, EnvironmentKind.localPosix);
    });

    test('a staging file a killed quit left is swept, not inherited', () async {
      // `_writeAtomically` cleans up in a `finally`, and a process that ends
      // between the write and the rename never runs it — which is what a quit
      // that cuts the sweep off at its 150 ms cap does. The soak found those
      // accumulating in the store homes, one per interrupted launch. Two
      // chances to be rid of one: the next install, and the next retirement.
      final claude = agents.firstWhere((a) => a.id == 'claudeCode');
      final home = storeHomeOf(claude);
      final staged = File('${endpointOf(claude).path}.karmashala-tmp');
      staged.writeAsStringSync('half of a token file');

      await installer.retireEndpoint(descriptor: claude, storeHome: home);

      expect(staged.existsSync(), isFalse);

      staged.writeAsStringSync('and again, from the launch after that');
      await installer.install(
        descriptor: claude,
        storeHome: home,
        endpoint: first,
        environment: EnvironmentKind.localPosix,
      );

      expect(staged.existsSync(), isFalse);
      expect(endpointOf(claude).existsSync(), isTrue);
    });

    test('the script and the config are not asked about', () async {
      // They carry nothing secret, and an ACL on a file the agent's own CLI
      // has to read is a way to break the hook rather than to protect it.
      final codex = agents.firstWhere((a) => a.id == 'codex');

      await tracked.install(
        descriptor: codex,
        storeHome: storeHomeOf(codex),
        endpoint: first,
        environment: EnvironmentKind.windowsNative,
      );

      expect(asked, hasLength(1));
      expect(asked.single.$1, contains('$agentHookMarker.endpoint'));
    });
  });

  for (final shell in _shells) {
    _runForReal(installer, agents, shell);
  }
}

/// The two interpreters an installed hook is handed to, and how to reach them.
///
/// Both are exercised where the machine has them, because the two scripts are
/// genuinely different programs: `for /f "eol=# tokens=1,* delims=="` against a
/// `while read` loop, `set /p` against `$( )`, CRLF against LF. A test that
/// only ever ran one of them would be asserting the text of the other.
const _shells = [
  (
    name: 'sh',
    executable: 'sh',
    prefix: <String>[],
    environment: EnvironmentKind.localPosix,
    extension: 'sh',
    // `head -c` cuts an oversized payload and posts what is left, so the probe
    // is followed by a callback.
    oversizedRequests: 2,
  ),
  (
    name: 'cmd.exe',
    executable: 'cmd.exe',
    prefix: <String>['/c'],
    environment: EnvironmentKind.windowsNative,
    extension: 'cmd',
    // `cmd` has no `head -c`: it spills stdin, measures it, and posts nothing
    // when it is over the bound. The probe is the only request.
    oversizedRequests: 1,
  ),
];

typedef _Shell = ({
  String name,
  String executable,
  List<String> prefix,
  EnvironmentKind environment,
  String extension,

  /// How many requests an over-bound payload puts on the wire here — the two
  /// shells stop differently, and the count is what each case waits for.
  int oversizedRequests,
});

void _runForReal(
  AgentHookInstaller installer,
  List<AgentDescriptor> agents,
  _Shell shell,
) {
  group('the generated ${shell.extension} script, run for real', () {
    // `sh`/`cmd.exe` and `curl` are what an installed hook actually runs, and
    // every other test in this area stands them in. Nothing below is a
    // stand-in: the script is the one the installer wrote, the endpoint file is
    // the one it wrote beside it, and the listener is a real socket. Skipped
    // where the machine has no such interpreter, because the alternative is
    // asserting the text of a shell script and calling that evidence.
    //
    // **The one thing here that is wall clock is the product's own**: the
    // installed script dials with `curl -m 2`, so on a machine loaded enough
    // that a loopback round trip does not finish inside two seconds the script
    // gives up — correctly. That bound cannot be counted away from this side.
    // What can be, and now is, is the test's own wait: `fire` returns when the
    // requests this case is about have been *recorded*, not when `curl` exited.
    final skip = _whyShellCannotRun(shell);

    late Directory scratch;
    late HttpServer server;
    late List<_Received> received;
    late int status;

    /// How many requests the case in flight is waiting for, and the completer
    /// that says they arrived. `curl` exits as soon as the response is written,
    /// while the handler recording it is still awaiting the body on this side —
    /// so the child's exit code is not the event the assertions are about.
    late int wanted;
    late Completer<void> quota;

    void record(_Received request) {
      received.add(request);
      if (received.length >= wanted && !quota.isCompleted) quota.complete();
    }

    setUp(() async {
      scratch = Directory.systemTemp.createTempSync('karmashala_hookrun_');
      received = [];
      wanted = 0;
      quota = Completer<void>();
      status = HttpStatus.unauthorized;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        record(
          _Received(
            authorization: request.headers.value(
              HttpHeaders.authorizationHeader,
            ),
            body: await utf8.decoder.bind(request).join(),
            query: request.uri.query,
          ),
        );
        // The real `_handleAgentHook` answers 401 to a request with no
        // credential and 200 to one with the right bearer, in that order.
        request.response.statusCode =
            request.headers.value(HttpHeaders.authorizationHeader) == null
            ? status
            : HttpStatus.ok;
        request.response.write('{"ok":true}');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      removeTempDirectory(scratch);
    });

    /// Installs Claude Code's hooks into [scratch] for [port] and runs the
    /// generated script for a `Stop` event, with a payload on stdin.
    ///
    /// Returns once the script has exited **and** [expectRequests] of them have
    /// been recorded. A case that expects none is bounded by the exit alone,
    /// because there is no event to wait for; one that expects some and never
    /// gets them hangs until the suite's timeout rather than failing on a
    /// count that was merely early, which is the trade a counted wait makes.
    Future<int> fire({
      int? port,
      int expectRequests = 0,
      void Function(File endpoint)? tamper,
      String payload = '{"session_id":"abc","cwd":"/tmp"}',
    }) async {
      wanted = expectRequests;
      quota = Completer<void>();
      if (expectRequests > 0 && received.length >= expectRequests) {
        quota.complete();
      }
      final claude = agents.firstWhere((a) => a.id == 'claudeCode');
      await installer.install(
        descriptor: claude,
        storeHome: scratch.path,
        endpoint: AgentHookEndpoint(
          port: port ?? server.port,
          token: 'secret-token-value',
        ),
        environment: shell.environment,
      );
      final endpoint = File(p.join(scratch.path, '$agentHookMarker.endpoint'));
      tamper?.call(endpoint);

      final process = await Process.start(shell.executable, [
        ...shell.prefix,
        p.join(scratch.path, '$agentHookMarker.${shell.extension}'),
        'Stop',
      ]);
      process.stdin.add(utf8.encode(payload));
      await process.stdin.close();
      await process.stdout.drain<void>();
      await process.stderr.drain<void>();
      final code = await process.exitCode;
      if (expectRequests > 0) await quota.future;
      return code;
    }

    test('posts the payload once the port answers 401', () async {
      // Counted: the probe and the callback, both recorded, before anything is
      // asserted about them.
      final exitCode = await fire(expectRequests: 2);

      expect(exitCode, 0);
      expect(received, hasLength(2));
      // The probe carries no credential and no body — it exists only to ask
      // whether this port is still ours.
      expect(received.first.authorization, isNull);
      expect(received.first.body, isEmpty);
      expect(received.first.query, contains('event='));
      // Then the real callback, with the token read out of the endpoint file
      // and the event appended to the URL.
      expect(received.last.authorization, 'Bearer secret-token-value');
      expect(received.last.body, '{"session_id":"abc","cwd":"/tmp"}');
      expect(received.last.query, contains('event=Stop'));
    }, skip: skip);

    test('nothing over the payload bound crosses the wire', () async {
      // The two shells stop differently and both stop: `sh` cuts with
      // `head -c`, `cmd` measures the spilled body and drops it. What has to
      // be true of either is the same sentence — the far end never sees more
      // than the bound — so that is what is asserted rather than a shell's
      // particular way of arriving at it. Only the *count* is per shell, and
      // it is named on the shell so the wait ends on the last request that is
      // going to arrive rather than on a guess.
      final exitCode = await fire(
        expectRequests: shell.oversizedRequests,
        payload: 'x' * (kAgentHookPayloadLimitBytes + 4096),
      );

      expect(exitCode, 0, reason: 'and it still costs the agent nothing');
      final callbacks = received
          .where((r) => r.authorization != null)
          .toList();
      for (final callback in callbacks) {
        expect(
          callback.body.length,
          lessThanOrEqualTo(kAgentHookPayloadLimitBytes),
        );
      }
      // The probe went out either way: the bound is about the payload, not
      // about whether the port is still ours.
      expect(received.first.authorization, isNull);
    }, skip: skip);

    test('hands nothing to a stranger that took the port', () async {
      // The hazard the service's own doc named: an unclean exit leaves the
      // endpoint file, the app's port is free, and something else binds it.
      // The probe is the whole guard — this listener answers 404 to a
      // credential-less GET, which ours never does.
      status = HttpStatus.notFound;

      // One request — the probe — and the assertion below is that nothing
      // followed it, so it is waited for rather than assumed.
      final exitCode = await fire(expectRequests: 1);

      expect(exitCode, 0, reason: 'and it still costs the agent nothing');
      expect(received, hasLength(1), reason: 'the probe, and then silence');
      expect(received.single.authorization, isNull);
      expect(received.single.body, isEmpty);
      // Which is the point: no token, and none of the agent's payload.
      for (final request in received) {
        expect(request.authorization, isNot(contains('secret-token-value')));
        expect(request.body, isNot(contains('session_id')));
      }
    }, skip: skip);

    test('a dead port costs one refused connection and nothing else', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close(force: true);

      final exitCode = await fire(port: port);

      expect(exitCode, 0);
      expect(received, isEmpty);
    }, skip: skip);

    test('no endpoint file means no dial at all', () async {
      // What the app leaves behind when it quits cleanly. The installed entry
      // and script stay in the user's config for ever; this is what they cost.
      final exitCode = await fire(tamper: (endpoint) => endpoint.deleteSync());

      expect(exitCode, 0);
      expect(received, isEmpty);
    }, skip: skip);

    test('a truncated endpoint file sends nothing', () async {
      // Half a file is what a process killed mid-write would leave if the
      // write were not staged and renamed. It must read as "do nothing"
      // rather than as a URL with no token, or a token with no URL.
      final exitCode = await fire(
        tamper: (endpoint) => endpoint.writeAsStringSync('url=http://127.'),
      );

      expect(exitCode, 0);
      expect(received, isEmpty);
    }, skip: skip);
  });
}

/// One request the fake listener saw.
class _Received {
  const _Received({
    required this.authorization,
    required this.body,
    required this.query,
  });

  final String? authorization;
  final String body;
  final String query;
}

/// Why [shell]'s cases cannot run here, or null when they can.
///
/// A skip, not a failure: `cmd.exe` is absent off Windows and a stock Windows
/// profile has no `sh` on its `PATH`, so between the two families every machine
/// runs one of them and a CI matrix runs both. What must never happen is a
/// silent pass — the reason is spelled out so a run that proved nothing says so.
String? _whyShellCannotRun(_Shell shell) {
  if (shell.executable == 'cmd.exe' && !Platform.isWindows) {
    return 'cmd.exe is Windows-only, and the .cmd script is only ever run '
        'there.';
  }
  for (final tool in [shell.executable, 'curl']) {
    try {
      Process.runSync(tool, const ['--version']);
    } on ProcessException {
      return '$tool is not on this machine, and it is what an installed hook '
          'runs. Run this suite where it is — a POSIX host, or WSL, for `sh`.';
    }
  }
  return null;
}
