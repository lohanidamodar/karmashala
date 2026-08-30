import 'dart:io';
import 'dart:isolate';

import 'package:chitragupta_local_ipc/chitragupta_local_ipc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('owner-only named pipe round-trips an RPC message', () async {
    if (!Platform.isWindows) return;
    final name =
        r'\\.\pipe\chitragupta-test-' +
        DateTime.now().microsecondsSinceEpoch.toString();
    final server = await NamedPipeRpcServer.start(
      name,
      (request) => 'ok:$request',
    );
    addTearDown(server.close);

    final response = await Isolate.run(
      () => NamedPipeRpcClient.call(name, 'ping'),
    );

    expect(response, 'ok:ping');
  });
}
