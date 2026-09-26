/// Re-exported, not defined: the constant lives in `karmashala_remote`, which
/// the host, the deployer and the phone all reach, while only this package can
/// be reached through `protocol.dart` by `karmashala_ssh`.
library;

export 'package:karmashala_remote/remote.dart' show kHostCompanionPort;
