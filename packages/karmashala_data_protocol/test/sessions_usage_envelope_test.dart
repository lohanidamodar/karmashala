import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// An agent's usage report crosses the wire whole, and a cost it never gave
/// reads back as none — not as zero.
void main() {
  Map<String, Object?> wire(Object? json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('sessionUsageChanged carries the context and the cost', () {
    const change = SessionUsageChanged(
      sessionId: 's1',
      contextUsed: 1800,
      contextSize: 200000,
      costAmount: 0.02,
      costCurrency: 'USD',
    );
    final read = DataChange.fromJson(wire(change.toJson()));
    expect(read, isA<SessionUsageChanged>());
    read as SessionUsageChanged;
    expect(read.sessionId, 's1');
    expect(read.contextUsed, 1800);
    expect(read.contextSize, 200000);
    expect(read.costAmount, 0.02);
    expect(read.costCurrency, 'USD');
  });

  test('no cost is left off the wire and reads back as none', () {
    const change = SessionUsageChanged(
      sessionId: 's1',
      contextUsed: 10,
      contextSize: 20,
    );
    final json = wire(change.toJson());
    expect(json.containsKey('costAmount'), isFalse);
    expect(json.containsKey('costCurrency'), isFalse);
    final read = DataChange.fromJson(json) as SessionUsageChanged;
    expect(read.costAmount, isNull);
    expect(read.costCurrency, isNull);
  });
}
