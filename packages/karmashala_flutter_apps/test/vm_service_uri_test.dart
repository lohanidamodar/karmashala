import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

void main() {
  group('normaliseVmServiceUri', () {
    test('keeps the address --vmservice-out-file writes, verbatim', () {
      // Verbatim what `--vmservice-out-file` wrote, 2026-09-08.
      expect(
        normaliseVmServiceUri('ws://127.0.0.1:53119/bt32nsO63q8=/ws')
            .toString(),
        'ws://127.0.0.1:53119/bt32nsO63q8=/ws',
      );
    });

    test('converts the address "flutter run" prints', () {
      // The printed form of the same address.
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
