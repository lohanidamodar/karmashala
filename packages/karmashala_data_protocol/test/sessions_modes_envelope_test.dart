import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// An agent's modes cross the wire whole: the request that
/// sets one and the change that tells what is offered.
void main() {
  Map<String, Object?> wire(Object? json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('sessions.setMode names the session and the mode', () {
    const request = SessionSetMode(sessionId: 's1', modeId: 'plan');
    final read = DataRequest.fromJson(
      request.kind,
      wire(request.argumentsToJson()),
    );
    expect(read, isA<SessionSetMode>());
    read as SessionSetMode;
    expect(read.sessionId, 's1');
    expect(read.modeId, 'plan');
    expect(read.kind, 'sessions.setMode');
    expect(
      request.resultFromJson(request.resultToJson(const DataAck())),
      isA<DataAck>(),
    );
  });

  test(
    'sessionModesChanged carries every mode, with and without a description',
    () {
      const change = SessionModesChanged(
        sessionId: 's1',
        currentModeId: 'default',
        availableModes: [
          SessionModeOption(id: 'default', name: 'Default'),
          SessionModeOption(
            id: 'plan',
            name: 'Plan',
            description: 'Reads and proposes; edits nothing.',
          ),
        ],
      );
      final read = DataChange.fromJson(wire(change.toJson()));
      expect(read, isA<SessionModesChanged>());
      read as SessionModesChanged;
      expect(read.sessionId, 's1');
      expect(read.currentModeId, 'default');
      expect(read.availableModes, change.availableModes);
      expect(read.current?.name, 'Default');
    },
  );

  test('no current mode and no modes at all both read back', () {
    const change = SessionModesChanged(
      sessionId: 's1',
      currentModeId: null,
      availableModes: [],
    );
    final read =
        DataChange.fromJson(wire(change.toJson()))! as SessionModesChanged;
    expect(read.currentModeId, isNull);
    expect(read.availableModes, isEmpty);
    expect(read.current, isNull);
  });

  test('a mode named by id alone takes the id as its name', () {
    final mode = SessionModeOption.fromJson({'id': 'yolo'});
    expect(mode.name, 'yolo');
    expect(mode.description, isNull);
  });

  test('sessions.setConfigOption carries a choice value or a flag', () {
    const pick = SessionSetConfigOption(
      sessionId: 's1',
      configId: 'model',
      value: 'claude-sonnet-5',
    );
    final read =
        DataRequest.fromJson(pick.kind, wire(pick.argumentsToJson()))
            as SessionSetConfigOption;
    expect(read.sessionId, 's1');
    expect(read.configId, 'model');
    expect(read.value, 'claude-sonnet-5');
    expect(read.kind, 'sessions.setConfigOption');

    const flag = SessionSetConfigOption(
      sessionId: 's1',
      configId: 'thinking',
      value: true,
    );
    final readFlag =
        DataRequest.fromJson(flag.kind, wire(flag.argumentsToJson()))
            as SessionSetConfigOption;
    expect(readFlag.value, true);

    expect(
      () => DataRequest.fromJson(pick.kind, {
        'sessionId': 's1',
        'configId': 'model',
        'value': 3,
      }),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          contains('must be a string or a bool'),
        ),
      ),
    );
  });

  test('sessionConfigOptionsChanged carries every option whole', () {
    const change = SessionConfigOptionsChanged(
      sessionId: 's1',
      options: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          category: 'model',
          currentValue: 'claude-sonnet-5',
          choices: [
            SessionConfigChoice(
              value: 'claude-sonnet-5',
              name: 'Claude Sonnet 5',
              description: 'Fast and capable.',
            ),
            SessionConfigChoice(
              value: 'gpt-6',
              name: 'GPT-6',
              group: 'Other providers',
            ),
          ],
        ),
        SessionConfigOption(
          id: 'thinking',
          name: 'Extended thinking',
          type: 'boolean',
          currentValue: false,
        ),
      ],
    );
    final read =
        DataChange.fromJson(wire(change.toJson()))!
            as SessionConfigOptionsChanged;
    expect(read.sessionId, 's1');
    expect(read.options, change.options);
    final model = read.option('model')!;
    expect(model.isSelect, isTrue);
    expect(model.isModel, isTrue);
    expect(model.isMode, isFalse);
    expect(
      const SessionConfigOption(
        id: 'x',
        name: 'Mode',
        type: 'select',
        category: 'mode',
      ).isMode,
      isTrue,
    );
    expect(model.current?.name, 'Claude Sonnet 5');
    expect(model.choices[1].group, 'Other providers');
    final thinking = read.option('thinking')!;
    expect(thinking.isBoolean, isTrue);
    expect(thinking.currentValue, false);
    expect(read.option('nope'), isNull);
  });

  test('an option with no options and a value not offered both read back', () {
    const change = SessionConfigOptionsChanged(sessionId: 's1', options: []);
    final read =
        DataChange.fromJson(wire(change.toJson()))!
            as SessionConfigOptionsChanged;
    expect(read.options, isEmpty);

    final option = SessionConfigOption.fromJson({
      'id': 'model',
      'type': 'select',
      'currentValue': 'unlisted',
      'choices': [
        {'value': 'a'},
      ],
    });
    expect(option.name, 'model');
    expect(option.current, isNull);
    expect(option.choices.single.name, 'a');
  });
}
