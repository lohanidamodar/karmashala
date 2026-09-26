import 'package:karmashala/src/core/database/sqlite_row_reader.dart';
import 'dart:io';

import 'package:agent_cli/ask.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/environments/application/environment_resolver.dart';
import 'package:karmashala/src/features/sessions/application/session_engine_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_stats_providers.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_session/launch.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../../support/temp_directory.dart';

/// **A fourth agent is one adapter and nothing else.**
///
/// Pi is made up. It exists only as the adapter below, registered beside the
/// shipped three — no id in the app, the daemon or the session engine names it
/// (`agent_id_branch_guard_test.dart` holds that line). Its descriptor declares
/// how it launches, what its hooks say and what its screen looks like; its
/// adapter overrides one capability (how it is asked one question) and declares
/// none of the rest. So the main paths work, and everything it lacks degrades
/// to "unknown" or "not offered" rather than to a crash or a guess.
const _pi = AgentDescriptor(
  id: 'piAgent',
  displayName: 'Pi Agent',
  binaries: AgentBinaries(windows: ['pi'], posix: ['pi']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    interactiveResume: AgentResume.flag('--session'),
    prompt: AgentPromptSupport.positional(),
  ),
  store: AgentStoreSpec(homeDirectoryName: '.pi'),
  statusStrategy: AgentStatusStrategy.hooks,
  hooks: AgentHookSpec(
    configFileName: 'hooks.json',
    sessionIdPath: ['session', 'id'],
    eventStatus: {
      'turn_start': AgentActivityStatus.working,
      'turn_end': AgentActivityStatus.idle,
    },
  ),
  grid: AgentGridRules(
    working: [GridMatcher('pi is thinking')],
    idle: [GridMatcher('pi ready')],
  ),
);

/// The whole of Pi's code.
class _PiAdapter extends AgentAdapter {
  const _PiAdapter();

  @override
  AgentDescriptor get descriptor => _pi;

  @override
  CliInvocation oneShot(String prompt, {String? systemPrompt, String? model}) =>
      CliInvocation(
        arguments: ['--print', prompt],
        parse: (line) => line.trim().isEmpty ? null : line.trim(),
      );
}

const _registry = AgentRegistry([...builtInAgentAdapters, _PiAdapter()]);

void main() {
  final pi = _registry.adapterFor('piAgent')!;

  test('it is registered by its adapter alone, and declares no capability', () {
    expect(pi, isA<_PiAdapter>());
    expect(_registry.byId('piAgent'), same(_pi));
    expect(_registry.displayNameFor('piAgent'), 'Pi Agent');
    // One override — `oneShot` — which is not a capability anything branches
    // on. Everything a caller does branch on is absent.
    expect(pi.capabilities, isEmpty);
    // The shipped agents keep theirs: adding Pi changed none of them.
    expect(
      _registry.adapterFor(AgentIds.claudeCode)!.capabilities,
      contains(AgentCapability.store),
    );
  });

  group('the main paths work', () {
    test('launch: the pane command line comes off its descriptor', () {
      final arguments = agentPaneArguments(
        _pi,
        PermissionSelection.parse('mode=ask')!,
        resumeSessionId: 's1',
        prompt: 'hello',
      );
      expect(arguments, ['--mode', 'ask', '--session', 's1', 'hello']);
    });

    test('launch: the engine gets a protocol for it through the registry', () {
      final container = ProviderContainer(
        overrides: [
          agentRegistryProvider.overrideWithValue(_registry),
          runnerResolverProvider.overrideWithValue((_) => FakeCommandRunner()),
        ],
      );
      addTearDown(container.dispose);

      final protocol = container.read(chatProtocolResolverProvider)('piAgent');
      // No protocol of its own, so the plain-text one, launched from the
      // descriptor.
      expect(protocol, isA<GenericChatProtocol>());
      expect(protocol.agentId, 'piAgent');
    });

    test('ask: its own one-shot override is used', () {
      final invocation = pi.oneShot('what time is it');
      expect(invocation.arguments, ['--print', 'what time is it']);
      expect(invocation.parse('  it is noon '), 'it is noon');
      // The same question, asked of a data-only agent with this descriptor,
      // would have fallen back to the prompt as its only argument.
      expect(DataOnlyAgentAdapter(_pi).oneShot('q').arguments, ['q']);
    });

    test('hooks: a callback is read by its declared hook spec', () {
      final receiver = AgentHookReceiver(
        registry: _registry,
        reports: AgentHookReports(),
        clock: FixedClock(testTime),
      );

      final report = receiver.handle(
        agentId: 'piAgent',
        event: 'turn_start',
        body: '{"session":{"id":"s1"}}',
      );

      expect(report.agentId, 'piAgent');
      expect(report.sessionId, 's1');
      expect(report.status, AgentActivityStatus.working);
      expect(
        receiver
            .handle(
              agentId: 'piAgent',
              event: 'turn_end',
              body: '{"session":{"id":"s1"}}',
            )
            .status,
        AgentActivityStatus.idle,
      );
    });

    test('status: its screen is read by its declared grid rules', () {
      const source = TerminalGridStatusSource();

      final working = source.read(
        _pi,
        ['output', 'pi is thinking…'],
        testTime,
        sessionId: 's1',
      );
      final idle = source.read(_pi, ['pi ready'], testTime, sessionId: 's1');

      expect(working?.status, AgentActivityStatus.working);
      expect(working?.source, AgentStatusSource.terminalGrid);
      expect(idle?.status, AgentActivityStatus.idle);
    });
  });

  group('what it lacks degrades rather than breaks', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_pi_'));
    tearDown(() => removeTempDirectory(tmp));

    test('no transcripts: the terminal, never a chat view', () {
      expect(agentSupportsChatView(pi), isFalse);
      expect(defaultViewFor(pi), SessionView.terminal);
    });

    test('no store: a declared home is located and read as nothing', () async {
      final home = '${tmp.path}/.pi';
      Directory(home).createSync();
      final store = CliStore(
        environmentId: 'windows',
        homesByAgentId: {'piAgent': home},
      );
      final detection = CliDetectionService(
        readRows: readSqliteRows,
        registry: _registry,
      );

      expect(detection.jobsFor([store]), isEmpty);
      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: home,
          store: pi.store,
          conversationId: 'c1',
        ),
        ConversationPresence.unknown,
      );
      expect(
        await const ConversationStoreIndex().idsIn(
          storeHome: home,
          store: pi.store,
        ),
        isNull,
        reason: 'nothing read is not "no conversations"',
      );
    });

    test('no store editor: rename and delete leave its store alone', () async {
      final transcript = File('${tmp.path}/c1.log')..writeAsStringSync('x');
      final session = DetectedSession(
        cli: 'piAgent',
        sessionId: 'c1',
        cwd: const EnvironmentPath(environmentId: 'windows', path: '/w'),
        filePath: transcript.path,
        storeHome: tmp.path,
      );
      final mutator = CliSessionMutator(registry: _registry);

      await mutator.rename(session, 'new name');
      expect(transcript.readAsStringSync(), 'x');

      final report = await mutator.deleteAll([session]);
      expect(report.isComplete, isTrue);
      expect(mutator.indexWrites, 0);
    });

    test('no usage endpoint: it is not asked, and says so', () async {
      final service = AgentUsageService(
        storeLocator: CliStoreLocator(runnerFor: (_) => FakeCommandRunner()),
        clock: FixedClock(testTime),
        registry: _registry,
      );

      await expectLater(
        service.fetch(
          agentInstallation(agentId: 'piAgent', path: r'C:\bin\pi.exe'),
          [windowsEnv()],
        ),
        throwsA(
          isA<UsageException>()
              .having((e) => e.kind, 'kind', UsageFailureKind.notAsked)
              .having((e) => e.message, 'message', contains('Pi Agent')),
        ),
      );
    });

    test('no stats, no undo, no accounts, no model list', () {
      expect(agentStoreRecordsStats(pi), isFalse);
      expect(pi.rewind, isA<UnknownRewind>());
      expect(pi.accounts, isNull);
      expect(pi.modelLister, isNull);
      expect(pi.fileChanges, isNull);
      expect(pi.media, isNull);
      expect(pi.directoryConversations, isNull);
      expect(pi.storeServer, isNull);
    });
  });
}
