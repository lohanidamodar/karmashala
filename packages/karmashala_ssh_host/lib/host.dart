/// Running the Karmashala host on an SSH box, as the server does (slice 5d):
/// which bundle a platform needs and where they are read from, deploying and
/// greeting one, installing and removing it, its relay, the port a phone
/// dials and a pairing window. The values it answers with are
/// `karmashala_host_protocol`'s (`host_access.dart`), re-exported here.
library;

export 'package:karmashala_host_protocol/host_access.dart';

export 'src/box_link.dart';
export 'src/companion_endpoint.dart';
export 'src/companion_port.dart';
export 'src/host_binaries.dart';
export 'src/host_deploy_target.dart';
export 'src/host_deployer.dart';
export 'src/host_deployment.dart';
export 'src/host_session_access.dart';
export 'src/relay_setup.dart';
export 'src/remote_pairing.dart';
