import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart'
    show ConfigOption, ConfigSelectOption;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// A model picked through a config option either moves or says in words why
/// it did not, and a choice the agent lists twice is offered once.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_choices_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  // Copilot 1.0.92's shape: `auto`, then the same models listed twice.
  const model = ConfigOption(
    id: 'model',
    name: 'Model',
    type: 'select',
    category: 'model',
    currentValue: 'claude-sonnet-5',
    options: [
      ConfigSelectOption(value: 'auto', name: 'Auto'),
      ConfigSelectOption(value: 'claude-sonnet-5', name: 'Claude Sonnet 5'),
      ConfigSelectOption(value: 'gpt-5-mini', name: 'GPT-5 mini'),
      ConfigSelectOption(value: 'claude-sonnet-5', name: 'Claude Sonnet 5'),
      ConfigSelectOption(value: 'gpt-5-mini', name: 'GPT-5 mini'),
    ],
  );

  test('a choice listed twice is announced once, at its first place, and '
      'still after a set', () async {
    final process = FakeAcpProcess(FakeAcpAgent(configOptions: [model]));
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    expect(
      host.configOptions.last.option('model')!.choices.map((c) => c.value),
      ['auto', 'claude-sonnet-5', 'gpt-5-mini'],
    );
    await runtime.setConfigOption('model', 'gpt-5-mini');
    final after = host.configOptions.last.option('model')!;
    expect(after.currentValue, 'gpt-5-mini');
    expect(after.choices, hasLength(3));
    await runtime.stop();
  });

  test('a set the agent acknowledges but does not take is refused in words, '
      'and the value it still holds is what is announced', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(configOptions: [model], ignoresConfigChanges: true),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    await expectLater(
      runtime.setConfigOption('model', 'gpt-5-mini'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Fake agent accepted the change but still reports "Model" as '
              '"Claude Sonnet 5", so nothing changed',
        ),
      ),
    );
    expect(
      host.configOptions.last.option('model')!.currentValue,
      'claude-sonnet-5',
    );
    await runtime.stop();
  });
}
