/// The phone's protocol client: the sealed session with a paired desktop, the
/// pairing exchange that creates one, the record of it at rest, the LAN path
/// and the relay candidates a dial works through. [CompanionStore] is an
/// interface because the record belongs in the platform keystore.
library;

export 'src/client/companion_client.dart';
export 'src/client/companion_pairing_client.dart';
export 'src/client/companion_store.dart';
export 'src/client/desktop_client.dart';
export 'src/client/lan_path.dart';
export 'src/client/relay_candidates.dart';
export 'src/client/route_pin.dart';
