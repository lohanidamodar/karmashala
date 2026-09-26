import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:path/path.dart' as p;

/// An instance whose data directory is too deep for a socket still gives its
/// agents their tools.
///
/// Found 2026-09-16 in a debug run with `KARMASHALA_DATA_DIR` inside the repo:
/// `ipc/rpc.sock` came to 125 bytes, macOS binds at most 103, and the bind
/// failed. The app kept running but withheld the privileged surface — the
/// handshake carried `hookToken`, `pid` and `port` and nothing an agent could
/// call through. `debug_run.bat -Fresh` puts it at 127 bytes on Windows.
void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rsl');
    container = ProviderContainer(overrides: []);
  });
  tearDown(() {
    container.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Something inside went while this walked.
    }
  });

  test(
    'a socket directory too deep to bind in still publishes a socket that answers',
    () async {
      final deep = p.join(tmp.path, 'd' * 60, 'e' * 40, 'ipc');
      final limit = maxSocketPathBytes(Platform.operatingSystem);
      expect(
        utf8.encode(p.join(deep, 'rpc.sock')).length,
        greaterThan(limit),
        reason: 'the case this is about: where it was put cannot be bound',
      );

      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      final server = LauncherControlServer(container);
      await server.start(bridgeFilePath: bridge, socketDirectory: deep);
      addTearDown(server.stop);

      final handshake =
          jsonDecode(File(bridge).readAsStringSync()) as Map<String, dynamic>;
      final socketPath = handshake['socketPath'] as String?;
      expect(
        socketPath,
        isNotNull,
        reason: 'withheld is the failure this fixes',
      );
      expect(handshake['token'], isNotNull);
      expect(utf8.encode(socketPath!).length, lessThanOrEqualTo(limit));
      expect(p.isWithin(deep, socketPath), isFalse);

      // Called the way the MCP bridge calls it: path and token from the handshake.
      final answer =
          jsonDecode(
                await LocalRpcClient.call(
                  socketPath,
                  jsonEncode({
                    'token': handshake['token'],
                    'tool': 'inbox_list',
                    'arguments': const <String, dynamic>{},
                  }),
                ),
              )
              as Map<String, dynamic>;
      expect(answer['ok'], isTrue, reason: '${answer['error']}');

      await server.stop();
      expect(
        File(socketPath).existsSync(),
        isFalse,
        reason: 'a stopped server leaves no node',
      );
    },
    testOn: 'mac-os || linux',
  );
}
