import 'dart:convert';

import 'package:karmashala_automations/webhooks.dart';
import 'package:test/test.dart';

const _secret = 'whsec_test_only_0123456789abcdef';
final _body = utf8.encode('{"action":"opened"}');
final _now = DateTime.utc(2026, 10, 6, 12);

WebhookSignature _check(
  Map<String, String> headers, {
  String secret = _secret,
}) => verifyWebhookSignature(
  secret: secret,
  headers: headers,
  body: _body,
  now: _now,
);

String _ts(DateTime at) => '${at.millisecondsSinceEpoch ~/ 1000}';

void main() {
  group('GitHub format', () {
    test('a good X-Hub-Signature-256 verifies', () {
      final signature = webhookSignatureFor(_secret, _body);
      expect(signature, startsWith('sha256='));
      expect(
        _check({'x-hub-signature-256': signature}),
        WebhookSignature.valid,
      );
    });

    test('a known GitHub vector verifies', () {
      // From GitHub's "Validating webhook deliveries" documentation.
      expect(
        verifyWebhookSignature(
          secret: "It's a Secret to Everybody",
          headers: {
            'x-hub-signature-256':
                'sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17',
          },
          body: utf8.encode('Hello, World!'),
          now: _now,
        ),
        WebhookSignature.valid,
      );
    });

    test('a wrong secret, a changed body or a bad format is invalid', () {
      final other = webhookSignatureFor('another secret', _body);
      expect(_check({'x-hub-signature-256': other}), WebhookSignature.invalid);
      expect(
        verifyWebhookSignature(
          secret: _secret,
          headers: {'x-hub-signature-256': webhookSignatureFor(_secret, _body)},
          body: utf8.encode('{"action":"closed"}'),
          now: _now,
        ),
        WebhookSignature.invalid,
      );
      expect(
        _check({'x-hub-signature-256': 'sha1=abc'}),
        WebhookSignature.invalid,
      );
      expect(
        _check({'x-hub-signature-256': 'sha256=zz'}),
        WebhookSignature.invalid,
      );
    });

    test('no signature header is missing', () {
      expect(_check(const {}), WebhookSignature.missing);
    });
  });

  group('the generic header', () {
    test('signs the timestamp and the body', () {
      final headers = webhookGenericHeaders(_secret, _body, at: _now);
      expect(headers['x-karmashala-timestamp'], _ts(_now));
      expect(_check(headers), WebhookSignature.valid);
    });

    test('outside the window is stale, whatever the signature', () {
      final old = _now.subtract(
        kWebhookTimestampWindow + const Duration(seconds: 1),
      );
      expect(
        _check(webhookGenericHeaders(_secret, _body, at: old)),
        WebhookSignature.stale,
      );
      final future = _now.add(
        kWebhookTimestampWindow + const Duration(seconds: 1),
      );
      expect(
        _check(webhookGenericHeaders(_secret, _body, at: future)),
        WebhookSignature.stale,
      );
    });

    test('a timestamp swapped after signing is invalid', () {
      final headers = webhookGenericHeaders(_secret, _body, at: _now);
      headers['x-karmashala-timestamp'] = _ts(
        _now.add(const Duration(seconds: 1)),
      );
      expect(_check(headers), WebhookSignature.invalid);
    });

    test('a signature without a timestamp is invalid', () {
      final headers = webhookGenericHeaders(_secret, _body, at: _now)
        ..remove('x-karmashala-timestamp');
      expect(_check(headers), WebhookSignature.invalid);
    });
  });

  test('an empty secret never verifies', () {
    expect(
      _check({
        'x-hub-signature-256': webhookSignatureFor('', _body),
      }, secret: ''),
      WebhookSignature.invalid,
    );
  });

  test('the comparison reads every byte', () {
    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
    expect(constantTimeEquals(const [], const []), isTrue);
  });

  test('the delivery id comes from the first header that names one', () {
    expect(
      webhookDeliveryId({'x-github-delivery': 'g', 'x-request-id': 'r'}),
      'g',
    );
    expect(webhookDeliveryId({'x-karmashala-delivery': 'k'}), 'k');
    expect(webhookDeliveryId({'x-request-id': ' r '}), 'r');
    expect(webhookDeliveryId(const {}), isNull);
    expect(webhookDeliveryId({'x-request-id': 'x' * 300}), hasLength(200));
  });

  test('the body hash is SHA-256 hex', () {
    expect(
      webhookBodyHash(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('secrets and hook ids come from a CSPRNG in the right shape', () {
    final ids = {for (var i = 0; i < 50; i++) newWebhookHookId()};
    expect(ids, hasLength(50));
    expect(ids.every(RegExp(r'^[0-9a-f]{32}$').hasMatch), isTrue);
    final secret = newWebhookSecret();
    expect(secret, startsWith('whsec_'));
    expect(secret.length, greaterThanOrEqualTo(6 + 43));
    expect(newWebhookSecret(), isNot(secret));
  });
}
