import 'package:agent_cli/process.dart';
import '../domain/wireless_pairing.dart';

/// Pure parsers for what `adb mdns`, `adb pair` and `adb connect` print. Every
/// string matched here was read out of the shipped `platform-tools 37.0.0`.

/// Reads `adb mdns check`. Success prints a `mdns daemon version [… discovery
/// 0.0.0]` line; adb has two backends and both answer in that shape, so the
/// version is matched rather than the backend's name.
MdnsAvailability parseMdnsCheck(CommandResult result) {
  final text = '${result.stdout}\n${result.stderr}';
  if (_discoveryDisabled.hasMatch(text)) return MdnsAvailability.disabled;
  if (!result.ok) return MdnsAvailability.unknown;
  if (_daemonVersion.hasMatch(text)) return MdnsAvailability.available;
  return MdnsAvailability.unknown;
}

/// Reads `adb mdns services`. Rows are `<name>\t<type>\t<host>:<port>`; a row
/// that is not is dropped rather than half-read, since half an address is none.
MdnsScan parseMdnsServices(CommandResult result) {
  final text = '${result.stdout}\n${result.stderr}';
  if (_discoveryDisabled.hasMatch(text)) {
    return const MdnsScan(availability: MdnsAvailability.disabled);
  }
  if (!result.ok) return const MdnsScan.unknown();

  final services = <MdnsService>[];
  for (final rawLine in result.stdout.split(RegExp(r'[\r\n]+'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('List of discovered')) continue;
    if (line.startsWith('*')) continue; // daemon chatter
    // Tabs are what adb writes; whitespace is the tolerant fallback, and a
    // service name may not contain either.
    final fields = line.split('\t').map((f) => f.trim()).toList();
    if (fields.length < 3) {
      fields
        ..clear()
        ..addAll(line.split(RegExp(r'\s+')));
    }
    if (fields.length < 3) continue;
    final address = parsePairingAddress(fields[2]);
    if (address == null) continue;
    services.add(
      MdnsService(
        name: fields[0],
        // Openscreen may append the root dot; the type is the same service.
        type: fields[1].endsWith('.')
            ? fields[1].substring(0, fields[1].length - 1)
            : fields[1],
        host: address.host,
        port: address.port,
      ),
    );
  }
  return MdnsScan(availability: MdnsAvailability.available, services: services);
}

/// Reads `adb pair HOST:PORT CODE`. Only the literal success line reads as
/// success: a pairing that silently "worked" leaves a phone that never connects.
AdbPairResult parsePairResult(CommandResult result) {
  final text = '${result.stdout}\n${result.stderr}';

  final paired = _pairedTo.firstMatch(text);
  if (paired != null) {
    final address = parsePairingAddress(paired.group(1)!);
    if (address != null) {
      return AdbPaired(
        host: address.host,
        port: address.port,
        guid: paired.group(2)!.trim(),
      );
    }
  }

  if (text.contains('Wrong password or connection was dropped')) {
    return const AdbPairRefused(
      cause: AdbPairFailure.wrongCode,
      message:
          'The pairing code was not accepted. Read it off the phone again — '
          'it changes every time the pairing dialog is opened.',
    );
  }
  if (text.contains('Unable to start pairing client') ||
      text.contains('unable to create pairing client')) {
    return const AdbPairRefused(
      cause: AdbPairFailure.unreachable,
      message:
          'Nothing answered on that pairing port. Either the pairing dialog '
          'on the phone has closed, or this machine cannot reach it — both '
          'have to be on the same Wi-Fi network, and some networks keep '
          'their clients apart.',
    );
  }
  if (text.contains('Failed to parse address for pairing') ||
      text.contains('Invalid port while parsing address')) {
    return const AdbPairRefused(
      cause: AdbPairFailure.malformedAddress,
      message:
          'adb could not read that as an address. It wants the IP address '
          'and port exactly as the phone shows them, separated by a colon.',
    );
  }
  if (text.contains('No pairing code provided')) {
    return const AdbPairRefused(
      cause: AdbPairFailure.noCode,
      message: 'adb was not given a pairing code.',
    );
  }
  return AdbPairRefused(
    cause: AdbPairFailure.unknown,
    message:
        'adb did not say whether the pairing worked. '
        '${_firstLine(text) ?? 'It printed nothing at all.'}',
  );
}

/// Reads `adb connect HOST:PORT`. `already connected to` counts as connected:
/// adb auto-connects to paired phones itself, so losing that race is a success.
AdbConnectOutcome parseConnectResult(CommandResult result) {
  final text = '${result.stdout}\n${result.stderr}';
  if (text.contains('failed to connect to') ||
      text.contains('failed to authenticate to') ||
      text.contains('unable to connect')) {
    return AdbConnectOutcome.refused;
  }
  if (RegExp(r'(already )?connected to \S+').hasMatch(text)) {
    return AdbConnectOutcome.connected;
  }
  return result.ok ? AdbConnectOutcome.unknown : AdbConnectOutcome.refused;
}

/// Reads `HOST:PORT` — an mDNS row's third field, or what the user typed. Split
/// at the **last** colon so an unbracketed IPv6 host keeps its own; a bare host
/// is rejected, because wireless debugging never uses a default port.
PairingAddress? parsePairingAddress(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  String host;
  String portText;
  if (text.startsWith('[')) {
    final close = text.indexOf(']');
    if (close < 0 || !text.startsWith(':', close + 1)) return null;
    host = text.substring(1, close);
    portText = text.substring(close + 2);
  } else {
    final colon = text.lastIndexOf(':');
    if (colon <= 0) return null;
    host = text.substring(0, colon);
    portText = text.substring(colon + 1);
  }

  if (host.isEmpty) return null;
  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) return null;
  return PairingAddress(host: host, port: port);
}

/// Whether what the user typed could be the phone's six-digit pairing code. A
/// shape check, not a validation: only the phone can say whether it is right.
bool isPlausiblePairingCode(String raw) =>
    RegExp(r'^\d{6}$').hasMatch(raw.trim());

String? _firstLine(String text) {
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

final RegExp _discoveryDisabled = RegExp(
  r'mdns discovery disabled',
  caseSensitive: false,
);
final RegExp _daemonVersion = RegExp(
  r'mdns daemon version',
  caseSensitive: false,
);
final RegExp _pairedTo = RegExp(
  r'Successfully paired to (\S+)\s*\[guid=([^\]]+)\]',
);
