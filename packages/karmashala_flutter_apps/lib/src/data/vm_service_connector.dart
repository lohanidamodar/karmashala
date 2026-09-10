import 'dart:io';

import 'package:vm_service/vm_service.dart';

/// Opens a VM service client for one `ws://…/ws` address — the seam this
/// feature is tested through; nothing else here calls `WebSocket.connect`.
typedef VmServiceConnector = Future<VmService> Function(Uri wsUri);

/// How long we wait for the socket itself. A dead loopback port is refused at
/// once; this bound is for a forwarded port whose far end is gone.
const Duration kVmServiceConnectTimeout = Duration(seconds: 5);

/// Connects over a real WebSocket. No `pingInterval`: a keepalive is a poll
/// (§19), and a VM service that goes away closes its socket by itself.
Future<VmService> connectVmServiceOverWebSocket(Uri wsUri) async {
  final socket = await WebSocket.connect(
    wsUri.toString(),
  ).timeout(kVmServiceConnectTimeout);
  return VmService(
    socket,
    socket.add,
    disposeHandler: () => socket.close(),
    streamClosed: socket.done,
    wsUri: wsUri.toString(),
  );
}
