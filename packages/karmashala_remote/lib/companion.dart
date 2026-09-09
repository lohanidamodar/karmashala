/// The companion app's one seam onto a paired desktop, and the real client
/// behind it.
///
/// `companionGatewayProvider` is deliberately NOT here: a Riverpod provider is
/// the app's wiring, not the gateway's contract. The app declares it over
/// [CompanionGateway] and [FakeCompanionGateway], both of which are.
library;

export 'src/companion/client/companion_gateway.dart';
export 'src/companion/client/fake_companion_gateway.dart';
export 'src/companion/client/pairing_input.dart';
export 'src/companion/client/remote_companion_gateway.dart';
