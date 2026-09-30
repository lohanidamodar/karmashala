import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:test/test.dart';

/// A PKCS#8 P-256 key built from a fixed scalar. It signs nothing real.
String throwawayPem() {
  final der = [
    ...[0x30, 0x41, 0x02, 0x01, 0x00],
    ...[0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01],
    ...[0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07],
    ...[0x04, 0x27, 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20],
    for (var byte = 1; byte <= 32; byte++) byte,
  ];
  return '-----BEGIN PRIVATE KEY-----\n'
      '${base64.encode(der)}\n'
      '-----END PRIVATE KEY-----\n';
}

AppleApiKey testKey({String? vendorNumber}) => AppleApiKey(
  keyId: 'KEYID12345',
  issuerId: '57246542-96fe-1a63-e053-0824d011072a',
  privateKeyPem: throwawayPem(),
  vendorNumber: vendorNumber,
);

const testApp = StoreApp(
  store: StoreKind.appStore,
  id: '1234567890',
  bundleId: 'com.example.app',
  name: 'Example',
);

final fixedNow = DateTime.utc(2026, 9, 30, 12);

http.Response jsonResponse(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

Matcher storeFailure(StoreFailure kind) =>
    throwsA(isA<StoreException>().having((e) => e.kind, 'kind', kind));
