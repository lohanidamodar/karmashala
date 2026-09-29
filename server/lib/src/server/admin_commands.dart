import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused, DeviceGrant, DevicesList;
import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;

import 'package:karmashala_host_protocol/protocol.dart';
import '../serve/client_command.dart';
import 'package:karmashala_host_protocol/host_paths.dart';
import 'pair_command.dart' show describeCapabilities, parseCapabilities;

/// `karmashala_host devices`: every phone paired with the running server.
Future<int> runDevices(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Map<String, String>? environment,
}) => _withServer('devices', paths, environment, err, (client) async {
  final sink = out ?? stdout;
  final devices = _devices(await client.call(ServerMethod.devicesList));
  if (devices.isEmpty) {
    sink.writeln('no paired devices — `karmashala_host pair` opens a window');
    return 0;
  }
  sink.writeln(
    formatTable([
      ['DEVICE', 'NAME', 'STATE', 'PAIRED', 'LAST SEEN', 'GRANTS'],
      for (final device in devices)
        [
          '${device['id']}',
          '${device['name']}',
          device['revoked'] == true ? 'revoked' : 'active',
          _day(device['pairedAt']),
          _day(device['lastSeenAt']),
          _grants(device['capabilities']),
        ],
    ]),
  );
  return 0;
});

/// `karmashala_host revoke <id>`: revokes one paired device — by its whole
/// id, or a prefix only it has — and drops its live links.
Future<int> runRevoke(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Map<String, String>? environment,
}) {
  final errSink = err ?? stderr;
  final named = args.where((a) => !a.startsWith('--')).toList();
  if (named.isEmpty) {
    errSink.writeln('karmashala_host revoke: name a device (see `devices`)');
    return Future.value(2);
  }
  return _withServer('revoke', paths, environment, err, (client) async {
    final sink = out ?? stdout;
    final wanted = named.first.trim().toLowerCase();
    final matches = [
      for (final device in _devices(
        await client.call(ServerMethod.devicesList),
      ))
        if ('${device['id']}'.startsWith(wanted) && device['revoked'] != true)
          device,
    ];
    if (matches.length != 1) {
      errSink.writeln(
        matches.isEmpty
            ? 'karmashala_host revoke: no active device has an id starting '
                  '"$wanted" (see `devices`)'
            : 'karmashala_host revoke: "$wanted" names ${matches.length} '
                  'devices; give more of the id',
      );
      return 2;
    }
    final revoked = await client.call(
      ServerMethod.devicesRevoke,
      arguments: {'deviceId': matches.single['id']},
    );
    final device = revoked['device'];
    final name = device is Map ? device['name'] : matches.single['name'];
    sink.writeln('revoked $name (${matches.single['id']})');
    return 0;
  });
}

/// `karmashala_host grant <id> --add=… --remove=…`: changes what one paired
/// device may do, by the same data-API grant the desktop's permissions dialog
/// sends — how a headless server gives an existing phone the app
/// (`--add=phone`). A switched link on the device is retired and reattaches.
Future<int> runGrant(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Map<String, String>? environment,
}) {
  final errSink = err ?? stderr;
  final named = args.where((a) => !a.startsWith('--')).toList();
  if (named.isEmpty) {
    errSink.writeln('karmashala_host grant: name a device (see `devices`)');
    return Future.value(2);
  }
  String? flag(String name) {
    for (final arg in args) {
      if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
    }
    return null;
  }

  final CapabilitySet add;
  final CapabilitySet remove;
  try {
    final adding = flag('add');
    final removing = flag('remove');
    if (adding == null && removing == null) {
      throw const FormatException('say what to --add or --remove');
    }
    add = adding == null ? CapabilitySet.none : parseCapabilities(adding);
    remove = removing == null
        ? CapabilitySet.none
        : parseCapabilities(removing);
  } on FormatException catch (error) {
    errSink.writeln('karmashala_host grant: ${error.message}');
    return Future.value(2);
  }
  return _withServer('grant', paths, environment, err, (client) async {
    final sink = out ?? stdout;
    final wanted = named.first.trim().toLowerCase();
    try {
      final matches = [
        for (final device in (await client.data(const DevicesList())).value)
          if (device.id.startsWith(wanted) && !device.revoked) device,
      ];
      if (matches.length != 1) {
        errSink.writeln(
          matches.isEmpty
              ? 'karmashala_host grant: no active device has an id starting '
                    '"$wanted" (see `devices`)'
              : 'karmashala_host grant: "$wanted" names ${matches.length} '
                    'devices; give more of the id',
        );
        return 2;
      }
      final device = matches.single;
      final granted = CapabilitySet(
        (device.capabilities.bits | add.bits) & ~remove.bits,
      );
      if (granted == device.capabilities) {
        sink.writeln('${device.name} already has that grant; nothing changed');
        return 0;
      }
      final updated = (await client.data(
        DeviceGrant(device.id, granted),
      )).value;
      sink.writeln(
        'granted ${updated.name} (${updated.id}): '
        '${describeCapabilities(updated.capabilities)}',
      );
      return 0;
    } on DataRefused catch (refusal) {
      errSink.writeln('karmashala_host grant: ${refusal.message}');
      return 6;
    }
  });
}

/// `karmashala_host agents [--refresh]`: the agent CLIs the running server
/// has recorded, or — with `--refresh` — found by probing again now.
Future<int> runAgents(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Map<String, String>? environment,
}) => _withServer('agents', paths, environment, err, (client) async {
  final sink = out ?? stdout;
  final refresh = args.contains('--refresh');
  final answer = await client.call(
    refresh ? ServerMethod.agentsRefresh : ServerMethod.agentsList,
    // Each agent's version is asked of its CLI, one process each.
    within: const Duration(minutes: 2),
  );
  final agents = answer['agents'];
  final rows = [
    for (final agent in agents is List ? agents : const [])
      if (agent is Map<String, Object?>) agent,
  ];
  if (rows.isEmpty) {
    sink.writeln(
      refresh
          ? 'no agent CLIs found'
          : 'no agent CLIs recorded — `karmashala_host agents --refresh` looks',
    );
  } else {
    sink.writeln(
      formatTable([
        ['AGENT', 'VERSION', 'PATH', ''],
        for (final agent in rows)
          [
            '${agent['name']}',
            '${agent['version'] ?? '?'}',
            '${agent['path']}',
            agent['added'] == true ? 'new' : '',
          ],
      ]),
    );
  }
  final summary = answer['summary'];
  if (summary is String) sink.writeln(summary);
  return 0;
});

Future<int> _withServer(
  String command,
  HostPaths? paths,
  Map<String, String>? environment,
  IOSink? err,
  Future<int> Function(HostClient client) body,
) async {
  final errSink = err ?? stderr;
  final resolved = hostPathsFor(
    command,
    paths: paths,
    environment: environment,
  );
  final HostClient? client;
  try {
    client = await HostClient.connect(resolved.socketPath);
  } on HostClientRefusal catch (error) {
    errSink.writeln('karmashala_host $command: $error');
    return 6;
  }
  if (client == null) {
    errSink.writeln(
      'karmashala_host $command: no server at ${resolved.socketPath}',
    );
    return 5;
  }
  try {
    return await body(client);
  } on HostClientRefusal catch (error) {
    errSink.writeln('karmashala_host $command: $error');
    return 6;
  } finally {
    await client.close();
  }
}

List<Map<String, Object?>> _devices(Map<String, Object?> answer) {
  final devices = answer['devices'];
  return [
    for (final device in devices is List ? devices : const [])
      if (device is Map<String, Object?>) device,
  ];
}

/// The wire names a device holds — `phone_client` among them or not is what
/// `grant --add=phone` is checked by.
String _grants(Object? wires) {
  final held = [
    for (final wire in wires is List ? wires : const []) '$wire',
  ];
  final named = CapabilitySet.of([
    for (final wire in held) ?Capability.tryParse(wire),
  ]);
  return named == CapabilitySet.all && held.length == named.granted.length
      ? 'all (${held.length} of ${Capability.values.length})'
      : held.isEmpty
      ? '-'
      : held.join(',');
}

String _day(Object? iso) {
  if (iso is! String) return '-';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return '-';
  final local = parsed.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// Rows padded to their widest cell, the last column left ragged.
String formatTable(List<List<String>> rows) {
  final columns = rows.first.length;
  final widths = [
    for (var i = 0; i < columns - 1; i++)
      rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b),
  ];
  return rows
      .map(
        (r) => [
          for (var i = 0; i < columns - 1; i++) r[i].padRight(widths[i]),
          r[columns - 1],
        ].join('  ').trimRight(),
      )
      .join('\n');
}
