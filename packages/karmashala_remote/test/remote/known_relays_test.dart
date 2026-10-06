import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// Which pairings move, decided in one place: only a pairing on a retired
/// PopupBits relay, never a self-hosted one or the LAN.
void main() {
  final known = KnownRelays(
    current: Uri.parse('wss://new.example.org'),
    retired: [Uri.parse('wss://old.example.org')],
  );

  group('moveTargetFor', () {
    test('a pairing on a retired relay moves to the current one', () {
      expect(
        known.moveTargetFor('wss://old.example.org'),
        Uri.parse('wss://new.example.org'),
      );
    });

    test('a retired relay matches however its URL is spelled', () {
      for (final spelling in [
        'wss://OLD.example.org/',
        'wss://old.example.org:443',
        'https://old.example.org',
        'wss://old.example.org?token=abc',
      ]) {
        expect(known.moveTargetFor(spelling), isNotNull, reason: spelling);
      }
    });

    test('self-hosted, local, current, missing and unreadable stay', () {
      for (final relay in [
        'wss://relay.my-own.net',
        'wss://old.example.org:8443',
        'wss://old.example.org/elsewhere',
        kLocalRelayMarker,
        'wss://new.example.org',
        null,
        '',
        'not a url',
      ]) {
        expect(known.moveTargetFor(relay), isNull, reason: '$relay');
      }
    });
  });

  test('a configured retired relay reads as the current one', () {
    expect(
      known.upgrade(Uri.parse('wss://old.example.org')),
      Uri.parse('wss://new.example.org'),
    );
    final own = Uri.parse('wss://relay.my-own.net');
    expect(known.upgrade(own), own);
    expect(known.upgrade(null), isNull);
  });

  test('PopupBits: the old fly.io relay moves to kmrelay', () {
    expect(
      KnownRelays.popupBits.moveTargetFor('wss://relay.popupbits.com'),
      Uri.parse(kPopupBitsRelayUrl),
    );
    expect(KnownRelays.popupBits.moveTargetFor(kPopupBitsRelayUrl), isNull);
  });

  test('sameRelay ignores case, a default port, a trailing slash and the '
      'query, and nothing else', () {
    expect(
      sameRelay(
        Uri.parse('wss://A.example.org:443/x/?t=1'),
        Uri.parse('https://a.example.org/x'),
      ),
      isTrue,
    );
    expect(
      sameRelay(
        Uri.parse('ws://a.example.org'),
        Uri.parse('wss://a.example.org'),
      ),
      isFalse,
    );
  });
}
