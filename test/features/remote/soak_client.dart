/// One end of a real relay run, as its own process.
///
/// Two of these — `--role host` and `--role companion` — pair through a running
/// relay, exchange sealed frames and print what they measured. Used to drive the
/// relay for real rather than only in-process:
///
/// ```
/// dart run test/features/remote/soak_client.dart --role host \
///     --relay ws://127.0.0.1:18787 --frames 2000 --size 1024
/// ```
///
/// Both ends derive the same device key and rendezvous from a pairing secret
/// given on the command line, so no secret is ever built into the file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/remote/transport/key_schedule.dart';
import 'package:karmashala/src/features/remote/transport/relay_transport.dart';
import 'package:karmashala/src/features/remote/transport/sealed_channel.dart';

/// Sent in every payload so a capture can be grepped for it.
const String kSoakMarker = 'PLAINTEXT-MUST-NOT-CROSS-THE-WIRE';

Future<void> main(List<String> arguments) async {
  final role = _arg(arguments, '--role') == 'host'
      ? ChannelRole.host
      : ChannelRole.companion;
  final relay = Uri.parse(_arg(arguments, '--relay') ?? 'ws://127.0.0.1:18787');
  final frames = int.parse(_arg(arguments, '--frames') ?? '1000');
  final size = int.parse(_arg(arguments, '--size') ?? '1024');
  final generation = int.parse(_arg(arguments, '--generation') ?? '0');
  final secret = utf8.encode(
    _arg(arguments, '--secret') ?? 'karmashala-soak-secret-32-bytes',
  );

  final deviceKey = await deriveDeviceKey(
    pairingSecret: secret,
    hostId: DeviceId.parse('11111111222222223333333344444444'),
    deviceId: DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd'),
  );
  final rendezvous = await rendezvousFor(deviceKey, generation);
  final channel = await SealedChannel.forDevice(
    deviceKey: deviceKey,
    role: role,
    generation: generation,
    maxForwardGap: frames * 2 + 16,
  );

  final transport = RelayTransport.connect(
    relay: relay,
    rendezvous: rendezvous,
    heartbeat: const Duration(seconds: 5),
  );
  final inbox = _Inbox(transport.frames);

  await _await(() => transport.isConnected, 'connect to the relay');
  stderr.writeln('${role.name}: connected to ${transport.endpoint}');

  // One hello each, so neither side blasts before the relay has paired them.
  transport.send(await channel.seal(utf8.encode('hello')));
  final hello = await channel.unseal(await inbox.next());
  if (utf8.decode(hello.plaintext) != 'hello') {
    stderr.writeln('${role.name}: bad hello');
    exit(1);
  }

  final filler =
      'x' *
      (size > kSoakMarker.length + 32 ? size - kSoakMarker.length - 32 : 1);
  final started = DateTime.now();

  var sent = 0;
  var received = 0;
  var receivedBytes = 0;
  var sentBytes = 0;

  final sending = () async {
    for (var i = 0; i < frames; i++) {
      final envelope = Envelope.of(
        role == ChannelRole.host
            ? FrameType.transcriptAppended
            : FrameType.promptSend,
        seq: channel.nextSendSequence,
        payload: {'i': i, 'marker': kSoakMarker, 'pad': filler},
      );
      final sealed = await channel.seal(envelope.toBytes());
      sentBytes += sealed.length;
      transport.send(sealed);
      sent++;
    }
  }();

  final receiving = () async {
    while (received < frames) {
      final frame = await inbox.next();
      receivedBytes += frame.length;
      final opened = await channel.unseal(frame);
      final envelope = Envelope.fromBytes(opened.plaintext);
      if (envelope.payload['i'] != received || envelope.seq != received + 1) {
        stderr.writeln(
          '${role.name}: out of order at $received: '
          'i=${envelope.payload['i']} seq=${envelope.seq}',
        );
        exit(1);
      }
      received++;
    }
  }();

  await Future.wait([sending, receiving]);
  final seconds =
      DateTime.now().difference(started).inMicroseconds /
      Duration.microsecondsPerSecond;

  stdout.writeln(
    jsonEncode({
      'role': role.name,
      'frames_sent': sent,
      'frames_received': received,
      'bytes_sent': sentBytes,
      'bytes_received': receivedBytes,
      'seconds': double.parse(seconds.toStringAsFixed(3)),
      'frames_per_second': (frames / seconds).round(),
      'megabits_per_second': double.parse(
        ((sentBytes + receivedBytes) * 8 / seconds / 1e6).toStringAsFixed(2),
      ),
      'highest_received_sequence': channel.highestReceivedSequence,
    }),
  );

  await transport.close();
  exit(0);
}

/// Buffers frames so the sender and the receiver can run at once.
class _Inbox {
  _Inbox(Stream<Uint8List> stream) {
    stream.listen(_frames.add);
  }

  final List<Uint8List> _frames = <Uint8List>[];

  Future<Uint8List> next() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (_frames.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        stderr.writeln('soak: no frame for 60s');
        exit(1);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return _frames.removeAt(0);
  }
}

Future<void> _await(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln('soak: timed out waiting to $what');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

String? _arg(List<String> arguments, String flag) {
  final index = arguments.indexOf(flag);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}
