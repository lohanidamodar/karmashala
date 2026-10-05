import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// A background agent is asked for by its run's id: a client that has no
/// path for it (the row naming its launch carries none) still opens it.
void main() {
  Map<String, Object?> wire(Object? json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('a subagent asked by its agent id crosses the wire with no path', () {
    const request = SessionTranscriptSubagent.ofAgent('s1', 'a4772db3', after: 5);
    final read =
        DataRequest.fromJson(request.kind, wire(request.argumentsToJson()))
            as SessionTranscriptSubagent;
    expect(read.sessionId, 's1');
    expect(read.agentId, 'a4772db3');
    expect(read.path, isEmpty);
    expect(read.after, 5);
  });

  test('one asked by its path still reads as before', () {
    const request = SessionTranscriptSubagent('s1', '/x/subagents/agent-a.jsonl');
    final args = wire(request.argumentsToJson());
    expect(args.containsKey('agentId'), isFalse);
    final read =
        DataRequest.fromJson(request.kind, args) as SessionTranscriptSubagent;
    expect(read.path, '/x/subagents/agent-a.jsonl');
    expect(read.agentId, isNull);
  });
}
