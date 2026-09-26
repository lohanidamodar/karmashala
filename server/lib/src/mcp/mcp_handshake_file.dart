import 'dart:io';

import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';

/// Writes [handshake] to [path] through a `.tmp` restricted to this account
/// while still empty. False — with nothing secret written — when [restrict]
/// is asked and the restriction did not apply.
Future<bool> writeMcpHandshake(
  String path,
  McpBridgeHandshake handshake,
  HandshakePermissions permissions, {
  bool restrict = true,
}) async {
  final staged = File('$path.tmp');
  if (staged.existsSync()) staged.deleteSync();
  staged.createSync(recursive: true);
  if (restrict && !await permissions.restrictFile(staged)) {
    staged.deleteSync();
    return false;
  }
  staged.writeAsStringSync(handshake.encode(), flush: true);
  staged.renameSync(path);
  return true;
}
