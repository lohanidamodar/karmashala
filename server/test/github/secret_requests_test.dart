import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/github/server_secret_requests.dart';
import 'package:karmashala_host/src/mcp/tools/secret_tool_set.dart';
import 'package:test/test.dart';

/// An agent asks for a secret; the owner answers a private card. The agent
/// gets a reference that works once and never the value, and a decline is
/// the agent's answer too.
void main() {
  late Directory data;
  late List<DataChange> told;
  late ServerSecretRequests requests;
  late SecretToolSet tools;

  setUp(() {
    data = Directory.systemTemp.createTempSync('secret-requests-');
    told = [];
    requests = ServerSecretRequests(
      dataDirectory: data.path,
      tell: told.addAll,
    );
    tools = SecretToolSet(requests);
  });

  tearDown(() => data.deleteSync(recursive: true));

  Future<Object?> ask() => tools.call('request_secret', {
    'label': 'Stripe signing secret',
    'reason': 'To verify the webhook you asked me to set up.',
  }, 's1')!;

  Future<SecretRequest> waiting() async {
    for (var i = 0; i < 50 && requests.pending.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return requests.pending.single;
  }

  test(
    'the owner saves it: the agent gets a reference, never the value',
    () async {
      final answer = ask();
      final card = await waiting();
      expect(card.sessionId, 's1');
      expect(card.label, 'Stripe signing secret');
      expect(
        told.whereType<SecretRequestsChanged>().last.requests.single.id,
        card.id,
      );
      await requests.handle(SecretProvide(card.id, 'whsec_owner_only'));
      final result = jsonEncode(await answer);
      expect(result, isNot(contains('whsec_owner_only')));
      final reference = (jsonDecode(result) as Map)['reference'] as String;
      expect(reference, startsWith(kSecretReferencePrefix));
      expect(requests.pending, isEmpty);
      expect(
        jsonEncode([for (final change in told) change.toJson()]),
        isNot(contains('whsec_owner_only')),
      );

      expect(await requests.redeem(reference), 'whsec_owner_only');
      expect(await requests.redeem(reference), isNull, reason: 'single use');
    },
  );

  test('a saved reference survives a restart until it is used', () async {
    final answer = ask();
    final card = await waiting();
    await requests.handle(SecretProvide(card.id, 'kept'));
    final reference =
        ((await answer)! as Map<String, Object?>)['reference']! as String;
    final again = ServerSecretRequests(dataDirectory: data.path, tell: (_) {});
    expect(await again.redeem(reference), 'kept');
    expect(
      await ServerSecretRequests(
        dataDirectory: data.path,
        tell: (_) {},
      ).redeem(reference),
      isNull,
    );
  });

  test('Decline answers the agent and keeps nothing', () async {
    final answer = ask();
    final card = await waiting();
    await requests.handle(SecretDecline(card.id));
    final result = (await answer)! as Map<String, Object?>;
    expect(result['status'], 'declined');
    expect(result.containsKey('reference'), isFalse);
    expect(requests.pending, isEmpty);
    await expectLater(
      requests.handle(SecretProvide(card.id, 'late')),
      throwsA(isA<DataRefused>()),
    );
  });

  test('nobody answering ends the wait with nothing saved', () async {
    final outcome = await requests.request(
      sessionId: 's1',
      label: 'x',
      reason: 'y',
      timeout: const Duration(milliseconds: 10),
    );
    expect(outcome, isA<SecretUnanswered>());
    expect(requests.pending, isEmpty);
  });

  test('a caller outside a session is refused', () async {
    await expectLater(
      tools.call('request_secret', {'label': 'x', 'reason': 'y'}, null)!,
      throwsA(isA<StateError>()),
    );
  });

  test('the requests travel with their label and reason, never a value', () {
    final request = SecretRequest(
      id: 'r1',
      sessionId: 's1',
      label: 'API key',
      reason: 'why',
      requestedAt: DateTime.utc(2026, 10, 8),
    );
    final change = SecretRequestsChanged([request]);
    final back = DataChange.fromJson(change.toJson()) as SecretRequestsChanged;
    expect(back.requests.single.label, 'API key');
    expect(const SecretProvide('r1', 'value').argumentsToJson(), {
      'id': 'r1',
      'value': 'value',
    });
    expect('${const SecretProvide('r1', 'value')}', isNot(contains('value')));
  });
}
