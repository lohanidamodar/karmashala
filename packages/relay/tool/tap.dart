/// A TCP tap in front of the relay, for proving what the relay can see.
///
/// It forwards every byte between a client and the relay and appends both
/// directions to a capture file. Point a client at the tap instead of the relay
/// and then grep the capture: if anything readable is in there, the end-to-end
/// sealing is broken.
///
/// ```
/// dart run tool/tap.dart --listen 18788 --forward 127.0.0.1:18787 \
///     --capture /tmp/relay-capture.bin
/// ```
///
/// Not part of the relay. It exists so an operator — or a user who does not
/// trust the operator — can check the claim rather than take it.
library;

import 'dart:io';

Future<void> main(List<String> arguments) async {
  final listenPort = int.parse(_arg(arguments, '--listen') ?? '18788');
  final forward = (_arg(arguments, '--forward') ?? '127.0.0.1:18787').split(
    ':',
  );
  final capturePath = _arg(arguments, '--capture') ?? 'relay-capture.bin';

  final capture = File(capturePath).openWrite();
  var captured = 0;

  final server = await ServerSocket.bind(InternetAddress.anyIPv4, listenPort);
  stdout.writeln(
    'tap: ${server.address.address}:${server.port} -> '
    '${forward[0]}:${forward[1]}, capturing to $capturePath',
  );

  server.listen((Socket client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(forward[0], int.parse(forward[1]));
    } on SocketException catch (error) {
      stderr.writeln('tap: upstream refused: $error');
      client.destroy();
      return;
    }
    void pipe(Socket from, Socket to) {
      from.listen(
        (data) {
          captured += data.length;
          capture.add(data);
          to.add(data);
        },
        onDone: to.destroy,
        onError: (Object _) => to.destroy(),
        cancelOnError: true,
      );
    }

    pipe(client, upstream);
    pipe(upstream, client);
  });

  Future<void> stop(ProcessSignal _) async {
    await capture.flush();
    await capture.close();
    stdout.writeln('tap: captured $captured bytes to $capturePath');
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(stop);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(stop);
}

String? _arg(List<String> arguments, String flag) {
  final index = arguments.indexOf(flag);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}
