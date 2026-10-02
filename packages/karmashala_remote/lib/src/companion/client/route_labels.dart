/// What the phone calls a route, in the picker, on the connection row and in
/// the sentence that says a pinned route is not answering.
library;

import '../../client/relay_candidates.dart'
    show defaultCompanionRelay, isLocalRelay;
import '../../client/route_pin.dart';

/// A relay by where it is, and **never by its path**: a relay on the person's
/// own box carries its access token there (`/k/<token>`), and a label is
/// something people screenshot.
String describeRelay(Uri url) {
  if (url.host == defaultCompanionRelay?.host) {
    return 'Hosted relay';
  }
  final at = url.hasPort ? '${url.host}:${url.port}' : url.host;
  return isLocalRelay(url) ? 'Relay on this network · $at' : 'Relay at $at';
}

String describeRoutePin(CompanionRoutePin pin) => switch (pin.kind) {
  CompanionRouteKind.auto => 'Automatic',
  CompanionRouteKind.lan => 'This network (LAN)',
  CompanionRouteKind.relay => describeRelay(pin.relay!),
};
