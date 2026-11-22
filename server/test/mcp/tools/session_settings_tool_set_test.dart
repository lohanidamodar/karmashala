import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_settings_tools.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_host/src/sessions/session_modes.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `session_settings` and `session_configure`: a session's model, thinking
/// level, mode and options, read off what its agent announced and changed
/// through the changers the session bar's requests land on.
void main() {
  final t0 = DateTime.utc(2026, 11, 22, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late DaemonAgentStatus status;
  late ServerToolContext context;
  late _Modes modes;
  late _Models models;
  late Map<String, AcpAnnounced> announced;
  late SessionToolSet tools;

  void insertSession(String id, {String? modelId}) =>
      SessionDao(database).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session $id',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: t0,
          modelId: modelId,
        ),
      );

  const effort = SessionConfigOption(
    id: 'effort',
    name: 'Effort',
    type: 'select',
    currentValue: 'medium',
    choices: [
      SessionConfigChoice(value: 'low', name: 'Low'),
      SessionConfigChoice(value: 'medium', name: 'Medium'),
      SessionConfigChoice(value: 'high', name: 'High'),
    ],
  );
  const model = SessionConfigOption(
    id: 'model',
    name: 'Model',
    type: 'select',
    currentValue: 'sonnet',
    choices: [
      SessionConfigChoice(value: 'sonnet', name: 'Sonnet'),
      SessionConfigChoice(value: 'opus', name: 'Opus'),
    ],
  );
  const fast = SessionConfigOption(
    id: 'fast',
    name: 'Fast mode',
    type: 'boolean',
    currentValue: false,
  );

  AcpAnnounced acp({
    List<SessionConfigOption> options = const [effort, model, fast],
  }) => (
    modes: const SessionModesChanged(
      sessionId: 'acp1',
      currentModeId: 'default',
      availableModes: [
        SessionModeOption(id: 'default', name: 'Default'),
        SessionModeOption(id: 'plan', name: 'Plan'),
      ],
    ),
    options: SessionConfigOptionsChanged(sessionId: 'acp1', options: options),
  );

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', t0.toIso8601String()],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    insertSession('pty1', modelId: 'sonnet');
    insertSession('acp1');
    registry = SessionRegistry(launcher: FakePtyLauncher());
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    final data = DataService(database, clock: () => t0);
    modes = _Modes();
    models = _Models();
    data
      ..sessionModes = modes
      ..sessionModels = models;
    context = ServerToolContext(
      database: database,
      data: data,
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    announced = {'acp1': acp()};
    tools = SessionToolSet(
      context,
      prompts: DaemonPromptAnswers(status: status, database: database),
      registry: registry,
      acpAnnounced: (id) => announced[id],
    );
  });

  tearDown(() async {
    context.close();
    await status.close();
    await registry.shutdown();
    database.close();
  });

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> arguments, {
    String? caller,
  }) async =>
      (await tools.call(tool, arguments, caller)!) as Map<String, Object?>;

  group('session_settings', () {
    test('reports an ACP session\'s model, thinking level, mode and every '
        'option with its kind and choices', () async {
      final read = await call('session_settings', {'sessionId': 'acp1'});
      expect(read['runsOver'], 'acp');
      expect(read['agent'], {'id': AgentIds.claudeCode, 'name': 'Claude Code'});
      final modelRead = read['model']! as Map;
      expect(modelRead['chosen'], contains('none chosen'));
      expect(modelRead['running'], 'not recorded');
      expect(modelRead['optionId'], 'model');
      expect(modelRead['current'], 'sonnet');
      expect(read['thinking'], {
        'optionId': 'effort',
        'current': 'medium',
        'choices': [
          {'value': 'low', 'name': 'Low'},
          {'value': 'medium', 'name': 'Medium'},
          {'value': 'high', 'name': 'High'},
        ],
      });
      expect((read['mode']! as Map)['current'], 'default');
      final options = (read['options']! as List).cast<Map>();
      expect(
        [for (final o in options) (o['id'], o['kind'])],
        [('effort', 'thinking_level'), ('model', 'model'), ('fast', 'other')],
      );
      expect(options.last['current'], false);
      expect(options.last.containsKey('choices'), isFalse);
    });

    test('a terminal session reports its model and the agent\'s models, and '
        'says plainly the rest cannot be set', () async {
      final read = await call('session_settings', {'sessionId': 'pty1'});
      expect(read['runsOver'], 'not running here');
      final modelRead = read['model']! as Map;
      expect(modelRead['chosen'], 'sonnet');
      expect([
        for (final c in (modelRead['choices']! as List).cast<Map>()) c['value'],
      ], contains('opus'));
      expect(read['thinking'], startsWith('not settable'));
      expect(read['mode'], startsWith('not settable'));
      expect(read['options'], startsWith('not settable'));
    });

    test('defaults to the calling session', () async {
      final read = await call('session_settings', const {}, caller: 'acp1');
      expect(read['sessionId'], 'acp1');
    });

    test('an unknown session is refused', () async {
      await expectLater(
        tools.call('session_settings', {'sessionId': 'nope'}, null),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('session_configure', () {
    test('thinking sets the thinking-level option to the value', () async {
      final answer = await call('session_configure', {
        'sessionId': 'acp1',
        'thinking': 'high',
      });
      expect(modes.options, [('acp1', 'effort', 'high')]);
      expect(answer['changes'], [
        {'setting': 'thinking', 'value': 'high', 'result': 'applied'},
      ]);
    });

    test('a choice is found by its name regardless of case', () async {
      await call('session_configure', {'sessionId': 'acp1', 'thinking': 'LOW'});
      expect(modes.options, [('acp1', 'effort', 'low')]);
    });

    test('an invalid value is refused with the choices, and nothing is '
        'changed', () async {
      await expectLater(
        tools.call('session_configure', {
          'sessionId': 'acp1',
          'mode': 'plan',
          'thinking': 'extreme',
        }, null),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            allOf(
              startsWith('Nothing was changed.'),
              contains('"extreme" is not a choice of "Effort"'),
              contains('"low" (Low), "medium" (Medium), "high" (High)'),
            ),
          ),
        ),
      );
      expect(modes.modes, isEmpty);
      expect(modes.options, isEmpty);
    });

    test('an ACP model goes through its model option; mode and options '
        'through theirs', () async {
      final answer = await call('session_configure', {
        'sessionId': 'acp1',
        'model': 'opus',
        'mode': 'plan',
        'options': {'fast': true},
      });
      expect(modes.options, [
        ('acp1', 'model', 'opus'),
        ('acp1', 'fast', true),
      ]);
      expect(modes.modes, [('acp1', 'plan')]);
      expect(models.set, isEmpty);
      expect(
        [for (final c in (answer['changes']! as List).cast<Map>()) c['result']],
        ['applied', 'applied', 'applied'],
      );
    });

    test('an ACP agent with no model option is moved by the model '
        'changer', () async {
      announced['acp1'] = acp(options: const [effort]);
      models.outcome = SessionModelOutcome.recorded;
      final answer = await call('session_configure', {
        'sessionId': 'acp1',
        'model': 'opus',
      });
      expect(models.set, [('acp1', 'opus')]);
      expect(
        (answer['changes']! as List).single,
        containsPair('result', 'recorded'),
      );
    });

    test(
      'model on a terminal session reports the changer\'s outcome',
      () async {
        models.outcome = SessionModelOutcome.afterTurn;
        final answer = await call('session_configure', {
          'sessionId': 'pty1',
          'model': 'opus',
        });
        expect(models.set, [('pty1', 'opus')]);
        final change = (answer['changes']! as List).single as Map;
        expect(change['setting'], 'model');
        expect(change['result'], 'held');
        expect(change['note'], contains('turn ends'));
      },
    );

    test('a terminal session refuses a model the agent does not offer, and '
        'thinking', () async {
      await expectLater(
        tools.call('session_configure', {
          'sessionId': 'pty1',
          'model': 'gpt-9',
          'thinking': 'high',
        }, null),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            allOf(
              contains('"gpt-9" is not one this agent offers'),
              contains('"opus"'),
              contains('thinking: not settable'),
            ),
          ),
        ),
      );
      expect(models.set, isEmpty);
    });

    test('a refusal from the agent is that change\'s result', () async {
      modes.refuse = 'The agent refused the option: busy';
      final answer = await call('session_configure', {
        'sessionId': 'acp1',
        'thinking': 'high',
      });
      expect((answer['changes']! as List).single, {
        'setting': 'thinking',
        'value': 'high',
        'result': 'refused',
        'reason': 'The agent refused the option: busy',
      });
    });

    test('defaults to the calling session', () async {
      await call('session_configure', {'thinking': 'low'}, caller: 'acp1');
      expect(modes.options, [('acp1', 'effort', 'low')]);
    });

    test('nothing asked is refused', () async {
      await expectLater(
        tools.call('session_configure', {'sessionId': 'acp1'}, null),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

class _Modes implements SessionModeChanger {
  final modes = <(String, String)>[];
  final options = <(String, String, Object)>[];
  String? refuse;

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    if (refuse case final why?) throw DataRefused.invalid(why);
    modes.add((sessionId, modeId));
  }

  @override
  Future<void> setConfigOption(
    String sessionId,
    String configId,
    Object value,
  ) async {
    if (refuse case final why?) throw DataRefused.invalid(why);
    options.add((sessionId, configId, value));
  }
}

class _Models implements SessionModelChanger {
  final set = <(String, String?)>[];
  SessionModelOutcome outcome = SessionModelOutcome.now;

  @override
  Future<SessionModelSet> setModel(String sessionId, String? modelId) async {
    set.add((sessionId, modelId));
    return SessionModelSet(outcome: outcome);
  }
}
