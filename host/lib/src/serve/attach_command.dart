import 'dart:async';
import 'dart:io';

import 'host_paths.dart';

/// A byte proxy between stdio and the host's socket, and deliberately nothing
/// more.
///
/// The app runs this over an SSH *exec* channel and speaks the protocol on
/// stdin/stdout. Because it parses nothing, the same bytes flow over a pipe in
/// a test and over a channel in production, and a protocol change needs no
/// change here at all. It is also why the local stage can skip this process
/// entirely and connect to the socket directly — see transport.dart.
Future<int> runAttach(
  List<String> args, {
  Stream<List<int>>? input,
  IOSink? output,
  IOSink? err,
}) async {
  final errSink = err ?? stderr;
  final paths = HostPaths.resolve();
  final Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress(paths.socketPath, type: InternetAddressType.unix),
      0,
    );
  } on SocketException catch (e) {
    // A distinct code so the deployer can tell "no host running" from "the
    // host refused me", and start one rather than giving up.
    errSink.writeln('karmashala_host attach: no host at ${paths.socketPath} (${e.osError?.message ?? e.message})');
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
    // Our end going away must close the socket, so the host observes the
    // disconnect instead of holding a half-open channel.
    onDone: () => unawaited(socket.close()),
    onError: (Object _) => finish(6),
    cancelOnError: true,
  );

  final code = await done.future;
  await toHost.cancel();
  await fromHost.cancel();
  await stdoutSink.flush();
  return code;
}
