import 'dart:async';
import 'dart:convert';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:test/test.dart';

import 'acp_agent_client_test.dart' show RecordingHandler;

const kFake = 'FAKE_TOKEN_123_not_real';

void main() {
  test(
    'an unknown notification never reaches updates, logs or output',
    () async {
      final fromAgent = StreamController<List<int>>();
      final toAgent = StreamController<List<int>>();
      final sent = <String>[];
      toAgent.stream.listen((b) => sent.add(utf8.decode(b)));
      final printed = <String>[];
      final client = await runZoned(
        () async => AcpAgentClient(
          AcpPeer(fromAgent.stream, toAgent.sink),
          handler: RecordingHandler(),
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      final updates = <SessionUpdateEvent>[];
      client.updates.listen(updates.add);

      void say(Map<String, Object?> message) =>
          fromAgent.add(utf8.encode('${jsonEncode(message)}\n'));
      say({
        'jsonrpc': '2.0',
        'method': '_x.ai/mcp/servers_updated',
        'params': {
          'servers': [
            {
              'name': 'grafana',
              'env': [
                {'name': 'GRAFANA_API_KEY', 'value': kFake},
              ],
            },
          ],
        },
      });
      say({
        'jsonrpc': '2.0',
        'method': AcpMethods.sessionUpdate,
        'params': {
          'sessionId': 's',
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'hello'},
          },
        },
      });
      await pumpEventQueue();

      expect(updates, hasLength(1));
      expect(printed.join(), isNot(contains(kFake)));
      expect(sent.join(), isNot(contains(kFake)));
      await client.close();
      await fromAgent.close();
    },
  );
}
