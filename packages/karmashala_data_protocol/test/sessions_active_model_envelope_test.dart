import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> wire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('sessionActiveModelChanged carries the model, when and from where', () {
    final change = SessionActiveModelChanged(
      sessionId: 's1',
      modelId: 'claude-opus-5-5',
      observedAt: DateTime.utc(2026, 10, 7, 9, 2, 13),
      source: ActiveModelSource.agent,
    );
    final read = DataChange.fromJson(wire(change.toJson()));
    expect(read, change);
  });

  test('a source this build does not know reads as the record', () {
    final json = wire(
      SessionActiveModelChanged(
        sessionId: 's1',
        modelId: 'gpt-6-astra',
        observedAt: DateTime.utc(2026, 10, 7),
      ).toJson(),
    )..['source'] = 'somethingNewer';
    final read = DataChange.fromJson(json) as SessionActiveModelChanged;
    expect(read.source, ActiveModelSource.record);
    expect(read.modelId, 'gpt-6-astra');
  });

  test('an older reader drops the change rather than failing', () {
    expect(
      DataChange.fromJson({
        'change': 'sessionSomethingNewer',
        'sessionId': 's1',
      }),
      isNull,
    );
  });

  test('a config option filed under the model category is the model', () {
    const option = SessionConfigOption(
      id: 'model_choice',
      name: 'Model',
      type: 'select',
      category: 'model',
    );
    expect(option.isModel, isTrue);
  });
}
