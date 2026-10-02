import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// An agent's modes (ACP design, C5) cross the wire whole: the request that
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
}
