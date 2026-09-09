import 'dart:io';

import 'package:vm_service/vm_service.dart';

/// Opens a VM service client for one `ws://…/ws` address.
///
/// **The seam this feature is tested through.** `VmService` takes a stream of
/// incoming messages and a function to write one, so a test hands it two ends
/// of a pair of controllers and answers JSON-RPC in Dart — no socket, no port,
/// no running app. Nothing under `features/flutter_apps` calls
/// `WebSocket.connect` except the default below.
typedef VmServiceConnector = Future<VmService> Function(Uri wsUri);

/// How long we wait for the socket itself.
///
/// A dead loopback port is refused immediately, so this bound is for the case
/// that is not a refusal — a forwarded port whose far end is gone, which is how
/// an unplugged phone behaves. Five seconds, matching `McpBridgeProbe`.
const Duration kVmServiceConnectTimeout = Duration(seconds: 5);

/// Connects over a real WebSocket.
///
/// **No `pingInterval`.** A keepalive is a timer asking "are you still there",
/// which is the third rule in §19; a VM service that goes away closes its
/// socket and `VmService.onDone` fires, so the answer arrives as an event
/// without anything being asked.
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
