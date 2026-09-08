import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/domain/vm_service_uri.dart';

void main() {
  group('normaliseVmServiceUri', () {
    test('keeps the address --vmservice-out-file writes, verbatim', () {
      // Measured 2026-09-08: this is the exact file content for
      // `flutter run -d windows --vmservice-out-file=C:\kw\vmsvc.uri`.
      expect(
        normaliseVmServiceUri('ws://127.0.0.1:53119/bt32nsO63q8=/ws')
            .toString(),
        'ws://127.0.0.1:53119/bt32nsO63q8=/ws',
      );
    });

    test('converts the address "flutter run" prints', () {
      // The line is: A Dart VM Service on Windows is available at:
      // http://127.0.0.1:53119/bt32nsO63q8=/
      expect(
        normaliseVmServiceUri('http://127.0.0.1:53119/bt32nsO63q8=/')
            .toString(),
        'ws://127.0.0.1:53119/bt32nsO63q8=/ws',
      );
    });

    test('keeps the auth token intact, "=" and all', () {
      final uri = normaliseVmServiceUri('http://127.0.0.1:1/AbC-_dEf=/');
      expect(uri!.pathSegments, ['AbC-_dEf=', 'ws']);
    });

    test('tolerates a half-converted address and a missing trailing slash', () {
      for (final raw in const [
        'ws://127.0.0.1:53119/tok=/',
        'ws://127.0.0.1:53119/tok=',
        '  http://127.0.0.1:53119/tok=  ',
      ]) {
        expect(
          normaliseVmServiceUri(raw).toString(),
          'ws://127.0.0.1:53119/tok=/ws',
          reason: raw,
        );
      }
    });

    test('upgrades a secure address to wss', () {
      expect(
        normaliseVmServiceUri('https://example.test:8080/tok=/').toString(),
        'wss://example.test:8080/tok=/ws',
      );
    });

    test('refuses anything that is not a VM service address', () {
      for (final raw in const [
        '',
        '   ',
        'not a uri at all',
        'file:///C:/tmp/out.txt',
        'ftp://127.0.0.1/tok=/',
        '53119',
      ]) {
        expect(normaliseVmServiceUri(raw), isNull, reason: 'accepted "$raw"');
      }
    });
  });

  group('describeVmServiceUri', () {
    test('renders the form a user can compare with their terminal', () {
      expect(
        describeVmServiceUri(Uri.parse('ws://127.0.0.1:53119/bt32nsO63q8=/ws')),
        'http://127.0.0.1:53119/bt32nsO63q8=/',
      );
    });

    test('round-trips', () {
      final ws = normaliseVmServiceUri('ws://127.0.0.1:53119/tok=/ws')!;
      expect(normaliseVmServiceUri(describeVmServiceUri(ws)), ws);
    });
  });
}
