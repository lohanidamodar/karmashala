import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart'
    show ConfigOption, ConfigSelectOption;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_extensions.dart';
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// The model an ACP agent is running is its own word: its `model` option's
/// value, or what a Karmashala bridge says the CLI under it resolved — and
/// never `default`. Each agent row keeps the model that wrote it.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_active_model_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  ConfigOption modelOption(String current) => ConfigOption(
    id: 'model',
    name: 'Model',
    type: 'select',
    category: 'model',
    currentValue: current,
    options: const [
      ConfigSelectOption(value: 'default', name: 'Default (recommended)'),
      ConfigSelectOption(value: 'gpt-6-astra', name: 'GPT-6 Astra'),
      ConfigSelectOption(value: 'gpt-6-astra-mini', name: 'GPT-6 Astra mini'),
    ],
  );

  Map<String, Object?> optionUpdate(String current) => {
    'sessionUpdate': 'config_option_update',
    'configOptions': [
      {
        'id': 'model',
        'name': 'Model',
        'type': 'select',
        'category': 'model',
        'currentValue': current,
        'options': [
          {'value': 'gpt-6-astra', 'name': 'GPT-6 Astra'},
          {'value': 'gpt-6-astra-mini', 'name': 'GPT-6 Astra mini'},
        ],
      },
    ],
  };

  List<(String, String?)> agentRows() => [
    for (final row in SessionMessageDao(database).listAfter('s1'))
      if (row.role == SessionMessageRole.agent) (row.text, row.model),
  ];

  test('the model option names it at start, and again when it is set or '
      'the agent moves it itself', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        configOptions: [modelOption('gpt-6-astra')],
        turns: [
          const FakeTurn([FakeStep.message('One.')]),
          FakeTurn([
            FakeStep.rawUpdate(optionUpdate('gpt-6-astra-mini')),
            const FakeStep.message('Two.'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    expect(host.activeModels, ['gpt-6-astra']);
    expect(runtime.activeModelId, 'gpt-6-astra');

    await runtime.send('hi');
    await runtime.awaitTurn();
    // The agent's own switch, as a /model typed into it would make.
    await runtime.send('again');
    await runtime.awaitTurn();
    expect(host.activeModels, ['gpt-6-astra', 'gpt-6-astra-mini']);
    expect(agentRows(), [
      ('One.', 'gpt-6-astra'),
      ('Two.', 'gpt-6-astra-mini'),
    ]);

    await runtime.setConfigOption('model', 'gpt-6-astra');
    expect(host.activeModels.last, 'gpt-6-astra');
    await runtime.stop();
  });

  test('`default` names no model; a bridge\'s word on what it resolved is '
      'the model, and lands on the row it arrived during', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        configOptions: [modelOption('default')],
        turns: [
          const FakeTurn([
            FakeStep.message('Hello.'),
            FakeStep.rawUpdate({
              'sessionUpdate': AcpExtensions.activeModel,
              'modelId': 'claude-opus-5-5',
            }),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    expect(host.activeModels, isEmpty);
    expect(runtime.activeModelId, isNull);

    await runtime.send('hi');
    await runtime.awaitTurn();
    expect(host.activeModels, ['claude-opus-5-5']);
    expect(agentRows(), [('Hello.', 'claude-opus-5-5')]);

    // The transcript a client reads carries it.
    final rows = SessionMessageDao(database).listAfter('s1');
    final read = SessionMessageTranscriptSource.project(
      rows.firstWhere((r) => r.role == SessionMessageRole.agent),
    );
    expect(read.model, 'claude-opus-5-5');
    expect(
      SessionMessageTranscriptSource.project(
        rows.firstWhere((r) => r.role == SessionMessageRole.user),
      ).model,
      isNull,
    );
    await runtime.stop();
  });
}
