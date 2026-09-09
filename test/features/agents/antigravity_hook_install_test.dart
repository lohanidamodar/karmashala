import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_installer.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// Antigravity's own hook configuration, which the descriptor used to say did
/// not exist.
///
/// Everything asserted here was read off a live `agy` 1.1.23 run against a
/// throwaway `HOME`, not off a document. The payloads are copied from that
/// run's log verbatim.
void main() {
  _absentStoreTests();

  const installer = AgentHookInstaller();
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');
  final antigravity = AgentRegistry.builtIn.byId('antigravity')!;

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_agyhook_');
    // The store the locator hands the installer, and the sibling directory the
    // CLI actually reads its customizations from.
    Directory(p.join(home.path, '.gemini', 'antigravity-cli')).createSync(
      recursive: true,
    );
  });
  tearDown(() => removeTempDirectory(home));

  String storeHome() => p.join(home.path, '.gemini', 'antigravity-cli');
  File hooksFile() => File(p.join(home.path, '.gemini', 'config', 'hooks.json'));
  File windowsScript() => File(p.join(storeHome(), '$agentHookMarker.cmd'));
  File endpointFile() =>
      File(p.join(storeHome(), '$agentHookMarker.endpoint'));

  Map<String, Object?> ours() {
    final root = jsonDecode(hooksFile().readAsStringSync()) as Map;
    return (root['karmashala'] as Map).cast<String, Object?>();
  }

  group('the descriptor', () {
    test('declares the events a live agy run actually fired', () {
      final spec = antigravity.hooks;
      expect(spec, isNotNull);
      expect(spec!.eventStatus, {
        // `SessionStart` is `working`, never `idle`. The event says a session
        // began, which is the one reading that cannot be wrong; the reason
        // Claude Code leaves it undeclared is that *its* `SessionStart` also
        // fires on `compact`, mid-turn, where a flat `idle` would call a busy
        // session finished. `working` has no such failure mode.
        'SessionStart': AgentActivityStatus.working,
        'PreInvocation': AgentActivityStatus.working,
        'PostInvocation': AgentActivityStatus.working,
        'Stop': AgentActivityStatus.idle,
      });
    });

    test('declares no PreToolUse hook, because one would deny tools', () {
      // Measured, not feared. With a `PreToolUse` handler that answers `{}` —
      // the only answer a status callback can honestly give, since it is not
      // a permission decision — a live `agy` run refused the tool outright:
      //
      //   Encountered error in tool execution: tool call denied by pre-tool
      //   hook
      //
      // The same run with only the flat events installed called the same tool
      // and got its result. A status hook may not decide permissions, so the
      // gating events are left undeclared.
      expect(antigravity.hooks!.eventStatus, isNot(contains('PreToolUse')));
      expect(antigravity.hooks!.eventStatus, isNot(contains('PostToolUse')));
    });

    test('reads the session id out of the key agy really sends', () {
      // `{"conversationId": "594f1ab1-…", …}` — protojson, so camelCase, and
      // nothing like Claude Code's `session_id`.
      expect(antigravity.hooks!.sessionIdPath, ['conversationId']);
      // `workspacePaths` is the working directory, and it arrives as a JSON
      // **array**. This assertion used to read `isEmpty`, on the belief that
      // the CLI always sent `[]`; the audit run found it populated, so the
      // path is declared and `_stringAt` reads a one-element list as its
      // string. There is no index in the path because a session has one
      // workspace. With this empty, adoption fell back to the oldest pane —
      // the wrong pane whenever more than one is open.
      expect(antigravity.hooks!.cwdPath, ['workspacePaths']);
    });
  });

  group('installing', () {
    test('writes agy\'s own hooks.json, beside the store and not in it', () async {
      // `~/.gemini/config/hooks.json` is the machine-local customization root;
      // the store home is `~/.gemini/antigravity-cli`, its sibling. Writing
      // inside the store home instead would put the file somewhere the CLI
      // never looks, which is the same as not installing at all.
      final installed = await installer.install(
        descriptor: antigravity,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(installed, isTrue);
      expect(hooksFile().existsSync(), isTrue);
      expect(
        File(p.join(storeHome(), 'hooks.json')).existsSync(),
        isFalse,
        reason: 'agy reads ~/.gemini/config, never its own data directory',
      );
    });

    test('names each event a flat list of handlers, as agy requires', () async {
      await installer.install(
        descriptor: antigravity,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(ours().keys.toSet(), {
        'SessionStart',
        'PreInvocation',
        'PostInvocation',
        'Stop',
      });
      // Flat: the handler object itself, with no `matcher`/`hooks` wrapper.
      // That wrapper is only for the tool events, which we do not install.
      final stop = (ours()['Stop']! as List).single as Map;
      expect(stop['type'], 'command');
      // A constant, exactly as Codex's is. Antigravity used to be given the
      // inline `curl` because the script was written only for an agent that
      // hashes its command — and this is the file the owner's machine had
      // emptied to `{}`, so it is the one that most needed to stop changing.
      expect(
        stop['command'],
        'cmd.exe /c "%USERPROFILE%\\.gemini\\antigravity-cli\\'
            '$agentHookMarker.cmd" Stop',
      );
      expect(stop['command'], isNot(contains('4242')));
      expect(stop['command'], isNot(contains('tok')));
      expect(stop.containsKey('hooks'), isFalse);
      expect(stop.containsKey('matcher'), isFalse);

      // The store home, not the config directory: `agy` keeps its data in
      // `~/.gemini/antigravity-cli` and reads `~/.gemini/config/hooks.json`,
      // and an earlier version of the installer refused to write a script at
      // all when those two differed.
      expect(windowsScript().existsSync(), isTrue);
      expect(
        endpointFile().readAsStringSync(),
        contains('url=http://127.0.0.1:4242/agent-hook'),
      );
      expect(endpointFile().readAsStringSync(), contains('token=tok'));
    });

    test('leaves another tool\'s named hook alone', () async {
      hooksFile().parent.createSync(recursive: true);
      hooksFile().writeAsStringSync(
        '{"lint-checker": {"Stop": [{"command": "./lint.sh"}]}}',
      );

      await installer.install(
        descriptor: antigravity,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      final root = jsonDecode(hooksFile().readAsStringSync()) as Map;
      expect(root['lint-checker'], {
        'Stop': [
          {'command': './lint.sh'},
        ],
      });
      expect((root['karmashala'] as Map).keys, contains('Stop'));
    });

    test('uninstall takes ours back out and leaves theirs', () async {
      hooksFile().parent.createSync(recursive: true);
      hooksFile().writeAsStringSync(
        '{"lint-checker": {"Stop": [{"command": "./lint.sh"}]}}',
      );
      await installer.install(
        descriptor: antigravity,
        storeHome: storeHome(),
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      final removed = await installer.uninstall(
        descriptor: antigravity,
        storeHome: storeHome(),
      );

      expect(removed, isTrue);
      final raw = hooksFile().readAsStringSync();
      expect(raw, isNot(contains(agentHookMarker)));
      expect(raw, contains('./lint.sh'));
      expect(windowsScript().existsSync(), isFalse);
      expect(endpointFile().existsSync(), isFalse);
    });

    test('an install that does not land is reported as such', () async {
      const silent = AgentHookInstaller(replace: _replaceButChangeNothing);

      expect(
        await silent.install(
          descriptor: antigravity,
          storeHome: storeHome(),
          endpoint: endpoint,
          environment: EnvironmentKind.windowsNative,
        ),
        isFalse,
      );
    });
  });

  group('receiving', () {
    late AgentHookReceiver receiver;
    setUp(() {
      receiver = AgentHookReceiver(
        registry: AgentRegistry.builtIn,
        reports: AgentHookReports(),
        clock: const SystemClock(),
      );
    });

    // Copied verbatim from the throwaway-HOME run's hook log.
    const stopPayload =
        '{"artifactDirectoryPath":"/tmp/ag/brain/594f1ab1",'
        '"conversationId":"594f1ab1-f352-4ce1-b92a-85dce890fcdd",'
        '"error":"","executionNum":0,"fullyIdle":true,'
        '"modelName":"gemini-3.7-flash-high",'
        '"terminationReason":"NO_TOOL_CALL","workspacePaths":[]}';

    test('a Stop callback names the conversation and says idle', () {
      final report = receiver.handle(
        agentId: 'antigravity',
        event: 'Stop',
        body: stopPayload,
      );

      expect(report.sessionId, '594f1ab1-f352-4ce1-b92a-85dce890fcdd');
      expect(report.status, AgentActivityStatus.idle);
      expect(report.source, AgentStatusSource.hook);
    });

    test('a PreInvocation callback says working', () {
      final report = receiver.handle(
        agentId: 'antigravity',
        event: 'PreInvocation',
        body:
            '{"conversationId":"594f1ab1-f352-4ce1-b92a-85dce890fcdd",'
            '"initialNumSteps":1,"invocationNum":0,"workspacePaths":[]}',
      );

      expect(report.sessionId, '594f1ab1-f352-4ce1-b92a-85dce890fcdd');
      expect(report.status, AgentActivityStatus.working);
    });
  });
}

Future<void> _replaceButChangeNothing(File staged, File destination) async {}

/// An agent whose store home is not on this machine.
///
/// The Antigravity *IDE* lives in `~/.gemini/antigravity`, its *CLI* in
/// `~/.gemini/antigravity-cli`; having the first and not the second is an
/// ordinary Mac. The installer used to try anyway and throw
/// `PathNotFoundException: .../karmashala-agent-hook.sh.karmashala-tmp` on
/// every launch, because the callback script lives *inside* the store home and
/// the guard that was supposed to cover this read "create the store home if the
/// store home exists".
void _absentStoreTests() {
  const installer = AgentHookInstaller();
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');
  final antigravity = AgentRegistry.builtIn.byId('antigravity')!;

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_agyabsent_');
    // Deliberately NOT created: this is a machine without the CLI installed.
  });
  tearDown(() => removeTempDirectory(home));

  String missingStore() => p.join(home.path, '.gemini', 'antigravity-cli');

  test('installing for an agent that is not installed reports false, '
      'rather than throwing', () async {
    // The install's own future, not a closure handed to `returnsNormally` and
    // a `pumpEventQueue()` that under load returned before the I/O finished —
    // which failed with `LateInitializationError` rather than the real answer.
    await expectLater(
      installer.install(
        descriptor: antigravity,
        storeHome: missingStore(),
        endpoint: endpoint,
        environment: EnvironmentKind.localPosix,
      ),
      completion(isFalse),
    );
  });

  test('and writes nothing into a home the agent does not have', () async {
    await installer.install(
      descriptor: antigravity,
      storeHome: missingStore(),
      endpoint: endpoint,
      environment: EnvironmentKind.localPosix,
    );

    // Creating the directory would be the other wrong answer: an empty agent
    // home in somebody's `~` for a tool they never installed.
    expect(Directory(missingStore()).existsSync(), isFalse);
    expect(
      Directory(p.join(home.path, '.gemini')).existsSync(),
      isFalse,
      reason: 'nothing at all should be created for an absent agent',
    );
  });
}
