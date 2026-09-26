/// The Karmashala relay's contract: what a client may send it and what it
/// answers. The relay server (`relay/`) and its clients — the phone's and the
/// host's relay transport, the push client, the server's `relay` command and
/// the desktop's embedded relay — all read it from here.
///
/// Values only: no I/O, no dependencies.
library;

export 'src/close_codes.dart';
export 'src/push.dart';
export 'src/routes.dart';
