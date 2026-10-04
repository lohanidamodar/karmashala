import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// The slash commands an agent accepts cross the wire whole, and a command
/// that takes no input reads back with no hint.
void main() {
  Map<String, Object?> wire(Object? json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('sessionCommandsChanged carries each command, its words and hint', () {
    const change = SessionCommandsChanged(
      sessionId: 's1',
      commands: [
        SessionCommand(
          name: 'review',
          description: 'Review the changes',
          hint: 'what to focus on',
        ),
        SessionCommand(name: 'compact', description: 'Compact the context'),
      ],
    );
    final json = wire(change.toJson());
    final read = DataChange.fromJson(json);
    expect(read, isA<SessionCommandsChanged>());
    read as SessionCommandsChanged;
    expect(read.sessionId, 's1');
    expect(read.commands, change.commands);
    expect(read.commands.last.hint, isNull);
    expect(
      (json['commands']! as List).last as Map,
      isNot(contains('hint')),
    );
  });

  test('an empty list is an agent with no commands', () {
    const change = SessionCommandsChanged(sessionId: 's1', commands: []);
    final read = DataChange.fromJson(wire(change.toJson()));
    expect((read! as SessionCommandsChanged).commands, isEmpty);
  });
}
