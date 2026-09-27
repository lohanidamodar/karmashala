import 'dart:async';
import 'dart:io';

import 'package:karmashala_host_protocol/host_paths.dart';

/// A byte proxy between stdio and the host's socket, deliberately nothing more:
/// because it parses nothing, a protocol change needs no change here.
Future<int> runAttach(
  List<String> args, {
  Stream<List<int>>? input,
  IOSink? output,
  IOSink? err,
  HostPaths? paths,
  Map<String, String>? environment,
}) async {
  final errSink = err ?? stderr;
  final resolved = hostPathsFor(
    'attach',
    paths: paths,
    environment: environment,
  );
  final Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress(resolved.socketPath, type: InternetAddressType.unix),
      0,
    );
  } on SocketException catch (e) {
    // A distinct code, so the deployer can tell "no host running" from
    // "the host refused me" and start one.
    errSink.writeln(
      'karmashala_host attach: no host at ${resolved.socketPath} (${e.osError?.message ?? e.message})',
    );
    return 5;
  }

  final stdinStream = input ?? stdin;
  final stdoutSink = output ?? stdout;
  final done = Completer<int>();
  void finish(int code) {
    if (!done.isCompleted) done.complete(code);
  }

  final fromHost = socket.listen(
    stdoutSink.add,
    onDone: () => finish(0),
    onError: (Object _) => finish(6),
    cancelOnError: true,
  );
  final toHost = stdinStream.listen(
    socket.add,
    // Our end going away must close the socket, or the host holds a half-open
    // channel instead of observing the disconnect.
    onDone: () => unawaited(socket.close()),
    onError: (Object _) => finish(6),
    cancelOnError: true,
  );

  final code = await done.future;
  await toHost.cancel();
  await fromHost.cancel();
  socket.destroy();
  // Bounded: a stdout whose reader died with its SSH channel never flushes.
  await stdoutSink
      .flush()
      .timeout(const Duration(seconds: 2), onTimeout: () {})
      .catchError((Object _) {});
  return code;
}
