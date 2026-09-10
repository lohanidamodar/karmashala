import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/util.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'support/temp_directory.dart';

/// Codex's hook configuration — the one agent that trusts a hook by hashing the
/// entry that declares it.
///
/// Everything asserted about the CLI here was read out of `openai/codex` at the
/// tag matching the 0.145.0 binary installed on this machine, and the shape of
/// the `config.toml` fixture is the shape of the owner's real one. Nothing here
/// runs `codex.exe`.
void main() {
  const installer = AgentHookInstaller();
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok-abc');
  final codex = AgentRegistry.builtIn.byId('codex')!;

  late Directory home;

  String storeHome() => p.join(home.path, '.codex');
  File hooksFile() => File(p.join(storeHome(), 'hooks.json'));
  File configToml() => File(p.join(storeHome(), 'config.toml'));
  File posixScript() => File(p.join(storeHome(), '$agentHookMarker.sh'));
  File windowsScript() => File(p.join(storeHome(), '$agentHookMarker.cmd'));
  File endpointFile() =>
      File(p.join(storeHome(), '$agentHookMarker.endpoint'));

  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_codexhook_');
    Directory(storeHome()).createSync(recursive: true);
  });
  tearDown(() => removeTempDirectory(home));

  Map<String, Object?> hooks() {
    final root = jsonDecode(hooksFile().readAsStringSync()) as Map;
    return (root['hooks'] as Map).cast<String, Object?>();
  }

  List<Map<String, Object?>> handlersFor(String event) => [
    for (final group in hooks()[event]! as List)
      for (final handler in (group as Map)['hooks'] as List)
        (handler as Map).cast<String, Object?>(),
  ];

  /// The shape of the owner's own `$CODEX_HOME/config.toml`: a third-party
  /// `notify` command, feature flags, per-project trust levels with Windows
  /// paths as keys, marketplace and plugin blocks, and MCP servers. None of it
  /// is ours, all of it would be unforgivable to lose, and the CLI writes the
  /// hook trust grant into this same file under `[hooks.state]`.
  const ownerShapedConfigToml = '''
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
personality = "pragmatic"

notify = [ "C:\\\\Users\\\\someone\\\\AppData\\\\Local\\\\Vendor\\\\turn-ended.exe", "turn-ended" ]
[windows]
sandbox = "elevated"

[features]
multi_agent = true
js_repl = false

[projects.'G:\\dev\\projects\\example']
trust_level = "trusted"

[projects."/mnt/c/Users/someone/Documents/example"]
trust_level = "trusted"

[marketplaces.vendor-bundled]
source_type = "local"
source = 'C:\\Users\\someone\\.codex\\.tmp\\bundled'

[plugins."github@vendor-curated"]
enabled = true

[mcp_servers.blender]
command = "uvx"
args = ["blender-mcp"]
''';

  group('the descriptor', () {
    test('declares only the events 0.145.0 knows, and no failure', () {
      final spec = codex.hooks;
      expect(spec, isNotNull);
      expect(spec!.eventStatus.keys.toSet(), {
        'UserPromptSubmit',
        'PreToolUse',
        'PostToolUse',
        'Stop',
        'SessionEnd',
      });
      // `Interrupt` is a twelfth event on the project's `main` and is absent
      // from the installed 0.145.0. `HooksFile` is `deny_unknown_fields`, so an
      // unknown event key makes the CLI discard the whole file — the user's
      // hooks along with ours — which is why it must never be declared here on
      // the strength of a newer branch.
      expect(spec.eventStatus.containsKey('Interrupt'), isFalse);
      // Codex fires no hook at all on a failed turn: `run_turn_stop_hooks` is
      // called only from the success branch of `core/src/session/turn.rs`, and
      // `SessionEnd`'s `reason` is the hard-coded constant `"other"`. Claiming
      // `failed` from any of these would be inventing it.
      expect(
        spec.eventStatus.values,
        isNot(contains(AgentActivityStatus.failed)),
      );
    });

    test('needs its command to stay identical between launches', () {
      expect(codex.hooks!.trustsCommandByHash, isTrue);
    });

    test('does not declare PermissionRequest', () {
      // The event exists, an observational handler on it is genuinely neutral,
      // and it is still the wrong signal: Codex consults its session approval
      // cache **after** the hook has run, so a call the user approved once "for
      // this session" fires `PermissionRequest` every time and prompts nobody.
      // Claiming `awaitingApproval` from it would put an ordinary working
      // session in the attention inbox.
      expect(codex.hooks!.eventStatus.containsKey('PermissionRequest'), isFalse);
    });
  });

  group('the receiver', () {
    late AgentHookReports reports;
    late AgentHookReceiver receiver;
    setUp(() {
      reports = AgentHookReports();
      receiver = AgentHookReceiver(
        registry: AgentRegistry.builtIn,
        reports: reports,
        clock: const SystemClock(),
      );
    });

    /// A real `PermissionRequestCommandInput`, in the flat `snake_case` shape
    /// `hooks/src/schema.rs` serializes.
    String permissionRequestPayload() => jsonEncode({
      'session_id': '019fa7a8-0000-7000-8000-000000000001',
      'turn_id': 'turn-1',
      'transcript_path': null,
      'cwd': 'C:\\dev\\example',
      'hook_event_name': 'PermissionRequest',
      'model': 'gpt-5.6-sol',
      'permission_mode': 'default',
      'tool_name': 'shell',
      'tool_input': {'command': 'npm test'},
    });

    test('claims nothing at all for a permission request', () {
      final report = receiver.handle(
        agentId: 'codex',
        event: 'PermissionRequest',
        body: permissionRequestPayload(),
      );

      // Not `awaitingApproval`, and not recorded either — so a session that was
      // working goes on saying it was working. `permission_mode` reads
      // `"default"` here exactly as it would for a cached approval that shows
      // the user nothing, which is why this payload cannot be believed.
      expect(report.status, AgentActivityStatus.unknown);
      expect(report.waiting, AgentWaitKind.unrecorded);
      expect(
        reports.latest('codex', '019fa7a8-0000-7000-8000-000000000001'),
        isNull,
      );
    });

    test('reads a declared event, and the session id it is keyed by', () {
      final report = receiver.handle(
        agentId: 'codex',
        event: 'PreToolUse',
        body: permissionRequestPayload(),
      );

      expect(report.status, AgentActivityStatus.working);
      expect(report.sessionId, '019fa7a8-0000-7000-8000-000000000001');
      // `tool_name` is the only thing in a Codex payload the agent named
      // itself. It is a name, not a sentence, and nothing else is invented
      // around it.
      expect(report.evidence, ['shell']);
      expect(report.waiting, AgentWaitKind.unrecorded);
    });

    test('claims no approval from any declared event', () {
      for (final event in codex.hooks!.eventStatus.keys) {
        final report = receiver.handle(
          agentId: 'codex',
          event: event,
          body: permissionRequestPayload(),
        );
        expect(
          report.status,
          isNot(AgentActivityStatus.awaitingApproval),
          reason: '$event must not put a session in the attention inbox',
        );
        expect(report.waiting, AgentWaitKind.unrecorded, reason: event);
      }
    });
  });

  group('the installed command', () {
    test('carries no port and no token, on any environment', () {
      for (final environment in [
        EnvironmentKind.windowsNative,
        EnvironmentKind.localPosix,
      ]) {
        final command = installer.hookCommand(
          descriptor: codex,
          event: 'Stop',
          endpoint: endpoint,
          environment: environment,
        );
        expect(command, isNotNull);
        expect(command, isNot(contains('4242')));
        expect(command, isNot(contains('tok-abc')));
        expect(command, contains(agentHookMarker));
        expect(command, endsWith(' Stop'));
      }
    });

    test('is byte-identical for a second launch on another port', () {
      // The whole point of the fixed script: Codex hashes this string, so a
      // launch that changed it would revoke the user's trust grant and stop
      // every callback until they granted it again.
      String commandWith(AgentHookEndpoint endpoint) => installer.hookCommand(
        descriptor: codex,
        event: 'PreToolUse',
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      )!;

      expect(
        commandWith(const AgentHookEndpoint(port: 5555, token: 'other')),
        commandWith(endpoint),
      );
    });

    test('names the home directory the store locator itself resolved', () {
      // `%USERPROFILE%` and `$HOME` are the two variables `CliStoreLocator`
      // reads, so the path the agent expands at run time is the path this
      // installer wrote to. Neither is resolved here, which is also what makes
      // the WSL command correct: the app reaches that store over a UNC name the
      // distribution cannot open.
      expect(
        installer.hookCommand(
          descriptor: codex,
          event: 'Stop',
          endpoint: endpoint,
          environment: EnvironmentKind.windowsNative,
        ),
        'cmd.exe /c "%USERPROFILE%\\.codex\\$agentHookMarker.cmd" Stop',
      );
      expect(
        installer.hookCommand(
          descriptor: codex,
          event: 'Stop',
          endpoint: endpoint,
          environment: EnvironmentKind.localPosix,
        ),
        'sh "\$HOME/.codex/$agentHookMarker.sh" Stop',
      );
    });
  });

  group('installing', () {
    test('writes one entry per event, and the script beside them', () async {
      final installed = await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );

      expect(installed, isTrue);
      expect(hooks().keys.toSet(), codex.hooks!.eventStatus.keys.toSet());
      final handler = handlersFor('Stop').single;
      expect(handler['type'], 'command');
      expect(handler['command'], contains(agentHookMarker));

      // The script carries no address and no token either — it reads them
      // out of the endpoint file beside it when the hook fires, which is what
      // makes *it* a constant too and leaves one file to rewrite per launch.
      final script = posixScript().readAsStringSync();
      expect(script, isNot(contains('127.0.0.1')));
      expect(script, isNot(contains('tok-abc')));
      expect(script, contains('$agentHookMarker.endpoint'));

      final endpointText = endpointFile().readAsStringSync();
      expect(endpointText, contains('url=http://127.0.0.1:4242/agent-hook'));
      expect(endpointText, contains('agent=codex'));
      expect(endpointText, endsWith('token=tok-abc\n'));
    });

    test('leaves a pre-existing user hook, and every sibling key', () async {
      // `HooksFile` allows exactly `description` and `hooks`, so a real file
      // that is not ours looks like this one.
      const existing = '''
{
  "description": "my own hooks",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "shell",
        "hooks": [
          {"type": "command", "command": "audit-shell.sh", "timeout": 5}
        ]
      }
    ],
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "greet.sh"}]}
    ]
  }
}''';
      hooksFile().writeAsStringSync(existing);

      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );

      // Their handler survives with its matcher and timeout untouched, and ours
      // is appended **after** it — the position the CLI keys its trust grant on.
      final preToolUse = hooks()['PreToolUse']! as List;
      expect(preToolUse, hasLength(2));
      final theirs = (preToolUse.first as Map).cast<String, Object?>();
      expect(theirs['matcher'], 'shell');
      expect(
        ((theirs['hooks']! as List).single as Map)['timeout'],
        5,
      );
      expect(
        handlersFor('PreToolUse').last['command'],
        contains(agentHookMarker),
      );
      // An event only they declared is not touched at all.
      expect(handlersFor('SessionStart').single['command'], 'greet.sh');
      expect(hooksFile().readAsStringSync(), contains('"my own hooks"'));
    });

    test('never opens config.toml, where the trust grant lives', () async {
      configToml().writeAsStringSync(ownerShapedConfigToml);

      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );
      await installer.uninstall(descriptor: codex, storeHome: storeHome());
      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: const AgentHookEndpoint(port: 5555, token: 'tok-2'),
        environment: EnvironmentKind.localPosix,
      );

      expect(configToml().readAsStringSync(), ownerShapedConfigToml);
    });

    test('rewrites the endpoint file for a new port, and nothing else', () async {
      hooksFile().writeAsStringSync(
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
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );
      final afterFirst = hooksFile().readAsStringSync();

      final installed = await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: const AgentHookEndpoint(port: 5555, token: 'tok-2'),
        environment: EnvironmentKind.localPosix,
      );

      expect(installed, isTrue);
      // The config is untouched — which is the property the trust grant
      // survives on — and so is the script, because it is a constant. One file
      // changed, and it is the one nothing else on the machine reads.
      expect(hooksFile().readAsStringSync(), afterFirst);
      expect(posixScript().readAsStringSync(), isNot(contains('5555')));
      expect(endpointFile().readAsStringSync(), contains('127.0.0.1:5555'));
      expect(endpointFile().readAsStringSync(), isNot(contains('4242')));
      expect(handlersFor('Stop').first['command'], 'mine.sh');
    });

    test('is refused for an environment it cannot report from', () async {
      final installed = await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.ssh,
      );

      // Another machine: it shares neither a loopback nor a filesystem with
      // this process, so a hook installed there would fire on every tool call
      // and never arrive.
      expect(installed, isFalse);
      expect(hooksFile().existsSync(), isFalse);
      expect(posixScript().existsSync(), isFalse);
      expect(windowsScript().existsSync(), isFalse);
      expect(endpointFile().existsSync(), isFalse);
    });
  });

  group('the script', () {
    test('discards the reply before it can be read as a decision', () async {
      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );

      final script = posixScript().readAsStringSync();
      // The endpoint answers `{"ok":true,"status":"…"}`. A hook that can decide
      // something reads its own stdout for that decision, so the body must not
      // reach it.
      expect(script, contains('-o /dev/null'));
      // And exit code 2 with stderr is Codex's deny channel, which `curl`
      // reaches on an option it cannot parse.
      expect(script.trimRight(), endsWith('exit 0'));
    });

    test('is a cmd batch file on Windows, and a shell script elsewhere', () async {
      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(posixScript().existsSync(), isFalse);
      final script = windowsScript().readAsStringSync();
      expect(script, startsWith('@echo off\r\n'));
      expect(script, contains('-o NUL'));
      // The event is still the script's one argument; what moved is the URL it
      // is appended to, which now comes out of the endpoint file.
      expect(script, contains(r'"%KS_URL%%~1"'));
      expect(script.trimRight(), endsWith('exit /b 0'));
      // CRLF for the batch file, and CRLF for the file `for /f` reads.
      expect(endpointFile().readAsStringSync(), contains('\r\n'));
    });
  });

  group('uninstalling', () {
    test('takes the script with it', () async {
      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );
      expect(posixScript().existsSync(), isTrue);

      final removed = await installer.uninstall(
        descriptor: codex,
        storeHome: storeHome(),
      );

      expect(removed, isTrue);
      // The one file in this feature that holds a bearer token in bytes of our
      // own must not outlive the app that minted it — and the script it is
      // read by goes with it.
      expect(posixScript().existsSync(), isFalse);
      expect(endpointFile().existsSync(), isFalse);
      expect(hooksFile().readAsStringSync(), isNot(contains(agentHookMarker)));
    });

    test('retiring the endpoint keeps the entry and the script', () async {
      // What the app does on the way out. The entry and the script are
      // constants with nothing stale in them; the address and the token are
      // not, and only they are removed. Taking the entry out here and putting
      // byte-identical bytes back on the next start is the churn that lost us
      // the race with the CLI that owns the file.
      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );
      final entry = handlersFor('Stop').single['command'];

      expect(
        await installer.retireEndpoint(
          descriptor: codex,
          storeHome: storeHome(),
        ),
        isTrue,
      );

      expect(endpointFile().existsSync(), isFalse);
      expect(posixScript().existsSync(), isTrue);
      expect(handlersFor('Stop').single['command'], entry);
      // And a second call has nothing left to do.
      expect(
        await installer.retireEndpoint(
          descriptor: codex,
          storeHome: storeHome(),
        ),
        isFalse,
      );
    });

    test('sweeps a script left by the other platform', () async {
      windowsScript().writeAsStringSync('@echo off\r\n');

      final removed = await installer.uninstall(
        descriptor: codex,
        storeHome: storeHome(),
      );

      expect(removed, isTrue);
      expect(windowsScript().existsSync(), isFalse);
    });

    test('a reinstall spells the same command it did before', () async {
      String stopCommand() => handlersFor('Stop').single['command']! as String;

      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );
      final before = stopCommand();

      await installer.uninstall(descriptor: codex, storeHome: storeHome());
      await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: const AgentHookEndpoint(port: 6161, token: 'tok-3'),
        environment: EnvironmentKind.localPosix,
      );

      // The grant Codex stores is keyed on the entry's hash and its position,
      // so an uninstall followed by an install has to reproduce both — which is
      // what lets `uninstallAll` run on the way out without costing the user a
      // fresh trust review on the way back in.
      expect(stopCommand(), before);
      expect(hooks()['Stop']! as List, hasLength(1));
    });
  });

  group('no token reaches a log line', () {
    test('nothing the installer returns carries one', () async {
      // The command, the URL and the script body all carry the token, so the
      // only thing that may cross this boundary is a bool. This is the shape of
      // the check rather than a proof about the logger: the installer has no
      // logger, and the service above it logs only agent and environment ids.
      final command = installer.hookCommand(
        descriptor: codex,
        event: 'Stop',
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );
      expect(command, isNot(contains('tok-abc')));

      final installed = await installer.install(
        descriptor: codex,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      );
      expect(installed, isTrue);
      expect(jsonEncode(hooks()), isNot(contains('tok-abc')));
      // Nor the script, which is now the only generated file anything else
      // ever reads out loud — the token is in the endpoint file alone.
      expect(posixScript().readAsStringSync(), isNot(contains('tok-abc')));
    });
  });
}
