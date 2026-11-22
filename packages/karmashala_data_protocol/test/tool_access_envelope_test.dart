import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// Agent tool access on the wire: the whole policy each way, as JSON text.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  const policy = <String, Object?>{
    'groups': {'answer': true},
    'messageAnyProject': true,
    'projects': {
      'p1': {
        'tools': {'pipeline_run': true},
      },
    },
  };

  test('the request carries the policy whole', () {
    final sent = DataEnvelope.readRequest(
      overTheWire(
        DataEnvelope.request(3, const AgentsToolAccessSet(policy: policy)),
      ),
    ).request!;
    expect(sent, isA<AgentsToolAccessSet>());
    expect((sent as AgentsToolAccessSet).policy, policy);
  });

  test('a policy that is not an object is refused', () {
    expect(
      () => DataRequest.fromJson(AgentsToolAccessSet.name, {'policy': 'all'}),
      throwsA(isA<DataRefused>()),
    );
  });

  test('the change carries the policy whole', () {
    final change = DataChange.fromJson(
      overTheWire(const ToolAccessChanged(policy).toJson()),
    );
    expect((change as ToolAccessChanged).policy, policy);
    final empty = DataChange.fromJson({'change': 'toolAccessChanged'});
    expect((empty as ToolAccessChanged).policy, isEmpty);
  });

  test('its key is the server\'s, not a preference', () {
    expect(PreferenceKeys.isReserved(kAgentToolAccessKey), isTrue);
  });
}
