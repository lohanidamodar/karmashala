import 'dart:io';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

import '../protocol/messages.dart';
import '../serve/client_command.dart';
import '../serve/host_paths.dart';
import 'terminal_qr.dart';

/// What `pair` grants when `--capabilities` is not given: everything, as the
/// desktop's dialog does — a server that offered less than the person chose
/// would be deciding something nobody asked it to.
const String kPairDefaultCapabilities = 'all';

/// `karmashala_host pair [--capabilities=<list|all>] [--relay=<url>]
/// [--name=<label>] [--address=<host[:port]>] [--no-color]`: opens a pairing
/// window at the running server — the same `pair` frame the desktop's dialog
/// sends — prints the code, its expiry, the payload and a QR code, then waits
/// until a device pairs or the window closes.
///
/// With `--address`, the QR is a host invite (`HostPairingInvite`) naming
/// where the phone dials, which is what a phone scanning a server on another
/// network needs; without, it is the pairing payload itself, as the desktop
/// shows it. [now] is for tests.
Future<int> runPair(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Map<String, String>? environment,
  DateTime Function()? now,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final clock = now ?? DateTime.now;
  final CapabilitySet capabilities;
  try {
    capabilities = parseCapabilities(
      _flag(args, 'capabilities') ?? kPairDefaultCapabilities,
    );
  } on FormatException catch (error) {
    errSink.writeln('karmashala_host pair: ${error.message}');
    return 2;
  }
  final relay = _flag(args, 'relay') ?? '';
  final label = _flag(args, 'name') ?? '';
  final address = _flag(args, 'address');
  final ansi =
      !args.contains('--no-color') &&
      !(environment ?? const {}).containsKey('NO_COLOR');

  final resolved = hostPathsFor('pair', paths: paths, environment: environment);
  final HostClient? client;
  try {
    client = await HostClient.connect(resolved.socketPath);
  } on HostClientRefusal catch (error) {
    errSink.writeln('karmashala_host pair: $error');
    return 6;
  }
  if (client == null) {
    errSink.writeln(
      'karmashala_host pair: no server at ${resolved.socketPath} — start one '
      'with `karmashala_host serve`',
    );
    return 5;
  }
  try {
    Map<String, Object?> info;
    try {
      info = await client.call(ServerMethod.serverInfo);
    } on HostClientRefusal {
      info = const {};
    }
    final companion = info['companion'];
    final serving = companion is Map<String, Object?> ? companion : const {};
    final name = info['name'] is String ? info['name']! as String : null;
    final port = serving['port'] is int ? serving['port']! as int : null;
    final bind = serving['bind'] is String ? serving['bind']! as String : null;

    final PairedMessage window;
    try {
      window = await client.pair(
        capabilities: capabilities.bits,
        relay: relay,
        label: label,
      );
    } on HostClientRefusal catch (error) {
      errSink.writeln('karmashala_host pair: $error');
      return 6;
    }
    final payload = PairingPayload.decode(window.payload);
    // A direct pairing's payload names a relay nobody waits at.
    final direct = payload.relay.host == 'invalid.local';
    final String qrText;
    String? endpoint;
    if (address != null) {
      endpoint = address.contains(':')
          ? address
          : '$address:${port ?? kHostCompanionPort}';
      try {
        qrText = HostPairingInvite(
          endpoint: endpoint,
          code: window.code,
          hostName: name ?? endpoint,
          route: direct ? HostRoute.direct : HostRoute.relay,
          relay: direct ? null : payload.relay,
          expiresAt: window.expiresAt,
        ).encode();
      } on ArgumentError {
        errSink.writeln(
          'karmashala_host pair: --address=$address is not an address a '
          'phone can dial (host[:port], and not loopback)',
        );
        return 2;
      }
    } else {
      qrText = window.payload;
    }

    final left = window.expiresAt.difference(clock().toUtc());
    sink
      ..writeln(
        'Pairing window open${name == null ? '' : ' on "$name"'} until '
        '${_clockTime(window.expiresAt.toLocal())} '
        '(${_minutes(left)}).',
      )
      ..writeln()
      ..writeln('  Code:     ${window.code}')
      ..writeln(
        '  Route:    ${direct ? 'direct' : 'relay ${scrubRelayLog('${payload.relay}')}'}',
      )
      ..writeln('  Grants:   ${describeCapabilities(capabilities)}');
    if (endpoint != null) sink.writeln('  Address:  $endpoint');
    if (label.isNotEmpty) sink.writeln('  Name:     $label');
    sink
      ..writeln()
      ..write(terminalQr(qrText, ansi: ansi))
      ..writeln()
      ..writeln(
        direct
            ? 'On the phone: scan the code above, or choose "Add machine" and '
                  'type this server\'s address and the code.'
            : 'On the phone: scan the code above — it names the relay the '
                  'phone meets this server at.',
      );
    for (final line in _reachability(
      direct: direct,
      address: address,
      bind: bind,
      port: port,
    )) {
      sink.writeln(line);
    }
    sink
      ..writeln()
      ..writeln('Payload (the same secret as the code — share it with nobody):')
      ..writeln(qrText)
      ..writeln()
      ..writeln(
        'Waiting for a device to pair… (Ctrl-C stops waiting; the window '
        'stays open until it expires)',
      );
    await sink.flush();

    final CompanionEventMessage ended;
    try {
      ended = await client.pairingEnded(
        window.requestId,
        within:
            (left.isNegative ? Duration.zero : left) +
            const Duration(seconds: 10),
      );
    } on HostClientRefusal {
      sink.writeln('The window expired with no device paired.');
      return 1;
    }
    final deviceId = ended.deviceId;
    if (deviceId == null) {
      sink.writeln(
        'The window closed with no device paired: ${ended.error ?? 'no reason given'}.',
      );
      return 1;
    }
    var deviceName = deviceId;
    try {
      final listed = await client.call(ServerMethod.devicesList);
      final devices = listed['devices'];
      for (final device in devices is List ? devices : const []) {
        if (device is Map && device['id'] == deviceId) {
          deviceName = '${device['name']} ($deviceId)';
        }
      }
    } on HostClientRefusal {
      // The pairing stands; only its name could not be read back.
    }
    sink.writeln('Paired: $deviceName');
    return 0;
  } finally {
    await client.close();
  }
}

/// `all`, or a comma-separated list of capability names
/// (`view_sessions,approve,…`). Throws [FormatException] naming the unknown
/// one and the known ones.
CapabilitySet parseCapabilities(String text) {
  final trimmed = text.trim();
  if (trimmed == 'all') return CapabilitySet.all;
  final chosen = <Capability>[];
  for (final part in trimmed.split(',')) {
    final name = part.trim();
    if (name.isEmpty) continue;
    final capability = Capability.tryParse(name);
    if (capability == null) {
      throw FormatException(
        'unknown capability "$name" — use "all" or a comma-separated list of '
        '${Capability.values.map((c) => c.wire).join(', ')}',
      );
    }
    chosen.add(capability);
  }
  if (chosen.isEmpty) {
    throw const FormatException('name at least one capability, or "all"');
  }
  return CapabilitySet.of(chosen);
}

/// "everything", or the names granted.
String describeCapabilities(CapabilitySet capabilities) =>
    capabilities.bits == CapabilitySet.all.bits
    ? 'everything'
    : [for (final c in capabilities.granted) c.wire].join(', ');

/// What stands between a phone and this window, said before anybody waits
/// on it: a listener only loopback can reach, or no address to dial.
List<String> _reachability({
  required bool direct,
  required String? address,
  required String? bind,
  required int? port,
}) {
  if (!direct) return const [];
  final loopbackOnly =
      bind != null && (InternetAddress.tryParse(bind)?.isLoopback ?? false);
  return [
    if (loopbackOnly)
      'Note: the phone listener is bound to $bind, so a phone cannot dial '
          'this server directly. Pair through a relay (--relay=<url>), or set '
          '"companion.bind" in server.json (0.0.0.0, or a tailnet address) and '
          'restart the server.',
    if (address == null && !loopbackOnly)
      'Note: no --address was given, so the QR does not say where to dial. '
          'Pass --address=<this machine\'s public or tailnet address> for a QR '
          'a phone on another network can use, or type that address and port '
          '${port ?? kHostCompanionPort} into "Add machine".',
  ];
}

String? _flag(List<String> args, String name) {
  String? found;
  for (final arg in args) {
    if (arg.startsWith('--$name=')) found = arg.substring(name.length + 3);
  }
  return found;
}

String _clockTime(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}:'
    '${at.second.toString().padLeft(2, '0')}';

String _minutes(Duration left) {
  if (left.isNegative) return 'already expired';
  final seconds = left.inSeconds;
  if (seconds < 90) return '$seconds s left';
  return '${(seconds / 60).round()} min left';
}
