import 'dart:convert';

import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// Webhooks through the envelope as JSON text: rotate, status, and the
/// change a recorded call tells.
void main() {
  final t0 = DateTime.utc(2026, 10, 6, 12);
  final call = WebhookCall(
    id: 'c1',
    automationId: 'auto1',
    hookId: '0123456789abcdef0123456789abcdef',
    receivedAt: t0,
    ip: '203.0.113.9',
    status: 202,
    outcome: 'accepted',
    bodyHash: 'ab' * 32,
    bodyBytes: 12,
    deliveryId: 'd1',
    sessionId: 's1',
    runId: 'run1',
  );

  R roundTrip<R>(DataRequest<R> request, R result) {
    final asked = jsonDecode(jsonEncode(DataEnvelope.request(1, request)));
    final read = DataEnvelope.readRequest(
      (asked as Map).cast<String, Object?>(),
    );
    expect(read.request!.kind, request.kind);
    expect(
      jsonEncode(read.request!.argumentsToJson()),
      jsonEncode(request.argumentsToJson()),
    );
    final answered = jsonDecode(
      jsonEncode(DataEnvelope.answer(1, request, DataReply(result, 3))),
    );
    return DataEnvelope.readAnswer(
      (answered as Map).cast<String, Object?>(),
      request,
    ).value;
  }

  test('rotate answers the new secret once, with the URL', () {
    final issued = roundTrip(
      const WebhookRotate('auto1'),
      const WebhookIssued(
        automationId: 'auto1',
        hookId: 'h',
        url: 'https://relay.example.com/h/l/h',
        secret: 'whsec_x',
      ),
    );
    expect(issued.secret, 'whsec_x');
    expect(issued.url, 'https://relay.example.com/h/l/h');
    expect(const WebhookRotate('a'), isA<WebhooksWorkRequest<Object?>>());
  });

  test('status answers the URL, the listener and the log — no secret', () {
    final status = roundTrip(
      const WebhookStatusRead('auto1', limit: 20),
      WebhookStatus(
        url: 'https://relay.example.com/h/l/h',
        listening: true,
        problem: null,
        calls: [call],
      ),
    );
    expect(status.listening, isTrue);
    expect(status.calls.single.sessionId, 's1');
    expect(
      jsonEncode(const WebhookStatusRead('auto1').argumentsToJson()),
      isNot(contains('secret')),
    );
  });

  test('a recorded call is a change every client hears', () {
    final change = DataChange.fromJson(
      (jsonDecode(jsonEncode(WebhookCallRecorded(call).toJson())) as Map)
          .cast<String, Object?>(),
    );
    expect(change, isA<WebhookCallRecorded>());
    expect((change! as WebhookCallRecorded).call.id, 'c1');
  });
}
