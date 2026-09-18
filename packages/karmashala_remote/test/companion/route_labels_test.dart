/// What the phone calls a route — and that no label ever carries the access
/// token a relay on the person's own box keeps in its path.
library;

import 'package:karmashala_remote/companion.dart';
import 'package:test/test.dart';

void main() {
  test('the hosted relay is named, not addressed', () {
    expect(describeRelay(Uri.parse(kDefaultCompanionRelayUrl)), 'Hosted relay');
  });

  test('a relay on this network says so, with where it is', () {
    expect(
      describeRelay(Uri.parse('ws://192.168.68.50:8787')),
      'Relay on this network · 192.168.68.50:8787',
    );
  });

  test('a relay on a box is named by its address and never by its token', () {
    final label = describeRelay(
      Uri.parse('ws://198.51.100.7:8787/k/s3cr3t-token'),
    );
    expect(label, 'Relay at 198.51.100.7:8787');
    expect(label, isNot(contains('s3cr3t')));
    expect(label, isNot(contains('/k/')));
  });

  test('every pin has a word', () {
    expect(describeRoutePin(CompanionRoutePin.auto), 'Automatic');
    expect(describeRoutePin(CompanionRoutePin.lan), 'This network (LAN)');
    expect(
      describeRoutePin(
        CompanionRoutePin.relay(Uri.parse('wss://relay.example.com/k/t')),
      ),
      'Relay at relay.example.com',
    );
  });
}
