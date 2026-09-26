import 'dart:convert';
import 'dart:io';

import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show CompanionConfig;
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:karmashala_remote/remote.dart' show kHostCompanionPort;
import 'package:path/path.dart' as p;

import '../mcp/mcp_credentials.dart' show writeOwnerOnly;
import '../mcp/mcp_endpoint_server.dart' show kPreferredMcpPort;

/// The server's own config file, in its data directory beside the store.
const String kServerConfigFileName = 'server.json';

/// A config that cannot be served by, in words: which file or flag, and why.
class ServerConfigError implements Exception {
  const ServerConfigError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What `server.json`, or a flag, says. Every field is "unset" when null, so
/// a flag can override one field of the file and leave the rest to it:
/// `file.overriddenBy(flags)`.
///
/// ```json
/// {
///   "name": "droplet",
///   "companion": {
///     "enabled": true, "bind": "0.0.0.0", "port": 47820, "beacon": false,
///     "relay": "wss://relay.example.com", "relayToken": "<32+ url-safe>",
///     "relayEnabled": true, "extraRelays": ["ws://box:8787/k/<token>"],
///     "notes": true
///   },
///   "mcp": {"port": 47821}
/// }
/// ```
class ServerConfig {
  const ServerConfig({
    this.name,
    this.companionEnabled,
    this.bind,
    this.companionPort,
    this.beacon,
    this.relay,
    this.relayToken,
    this.relayEnabled,
    this.extraRelays,
    this.notes,
    this.mcpPort,
  });

  static const ServerConfig empty = ServerConfig();

  /// What phones and the pairing QR call this server.
  final String? name;

  /// Whether phones are served at all.
  final bool? companionEnabled;

  /// The address the phone listener binds: an IP literal.
  final String? bind;
  final int? companionPort;

  /// Whether to announce this server on the LAN beacon.
  final bool? beacon;

  /// The relay pairings default to and rows fall back to.
  final Uri? relay;

  /// [relay]'s access token (`/k/<token>`), kept apart so the URL can be
  /// shown without it.
  final String? relayToken;

  /// Whether [relay] is served. Off keeps the URL — the desktop's "Hosted
  /// relay" switch — and parks the phones paired through it.
  final bool? relayEnabled;

  /// More relays this server listens on, each a full URL (token included).
  final List<Uri>? extraRelays;

  /// Whether a phone's `notes.get` answers.
  final bool? notes;

  /// The port agents' MCP endpoint prefers. Always loopback.
  final int? mcpPort;

  /// This, with every field [other] sets taken from [other].
  ServerConfig overriddenBy(ServerConfig other) => ServerConfig(
    name: other.name ?? name,
    companionEnabled: other.companionEnabled ?? companionEnabled,
    bind: other.bind ?? bind,
    companionPort: other.companionPort ?? companionPort,
    beacon: other.beacon ?? beacon,
    relay: other.relay ?? relay,
    relayToken: other.relayToken ?? relayToken,
    relayEnabled: other.relayEnabled ?? relayEnabled,
    extraRelays: other.extraRelays ?? extraRelays,
    notes: other.notes ?? notes,
    mcpPort: other.mcpPort ?? mcpPort,
  );

  Map<String, Object?> toJson() {
    final companion = <String, Object?>{
      'enabled': ?companionEnabled,
      'bind': ?bind,
      'port': ?companionPort,
      'beacon': ?beacon,
      'relay': ?relay?.toString(),
      'relayToken': ?relayToken,
      'relayEnabled': ?relayEnabled,
      if (extraRelays != null)
        'extraRelays': [for (final uri in extraRelays!) uri.toString()],
      'notes': ?notes,
    };
    return {
      'name': ?name,
      if (companion.isNotEmpty) 'companion': companion,
      if (mcpPort != null) 'mcp': {'port': mcpPort},
    };
  }

  /// Reads [json] — the file's contents — checking every field it sets.
  /// Throws [ServerConfigError] naming [source] and the field.
  static ServerConfig fromJson(Object? json, {required String source}) {
    Never refuse(String why) => throw ServerConfigError('$source: $why');
    if (json is! Map<String, Object?>) refuse('not a JSON object');
    for (final key in json.keys) {
      if (!const {'name', 'companion', 'mcp'}.contains(key)) {
        refuse('unknown key "$key" (known: name, companion, mcp)');
      }
    }
    final companion = json['companion'] ?? const <String, Object?>{};
    if (companion is! Map<String, Object?>) {
      refuse('"companion" is not an object');
    }
    for (final key in companion.keys) {
      if (!_companionKeys.contains(key)) {
        refuse(
          'unknown key "companion.$key" (known: ${_companionKeys.join(', ')})',
        );
      }
    }
    final mcp = json['mcp'] ?? const <String, Object?>{};
    if (mcp is! Map<String, Object?>) refuse('"mcp" is not an object');
    for (final key in mcp.keys) {
      if (key != 'port') refuse('unknown key "mcp.$key" (known: port)');
    }

    T? typed<T>(Map<String, Object?> map, String key, String path) {
      final value = map[key];
      if (value == null) return null;
      if (value is! T) refuse('"$path" must be a ${_typeName<T>()}');
      return value as T;
    }

    final extras = companion['extraRelays'];
    if (extras != null && extras is! List) {
      refuse('"companion.extraRelays" must be a list of URLs');
    }
    return validated(
      ServerConfig(
        name: typed<String>(json, 'name', 'name'),
        companionEnabled: typed<bool>(
          companion,
          'enabled',
          'companion.enabled',
        ),
        bind: typed<String>(companion, 'bind', 'companion.bind'),
        companionPort: typed<int>(companion, 'port', 'companion.port'),
        beacon: typed<bool>(companion, 'beacon', 'companion.beacon'),
        relay: _uri(
          typed<String>(companion, 'relay', 'companion.relay'),
          '$source: "companion.relay"',
        ),
        relayToken: typed<String>(
          companion,
          'relayToken',
          'companion.relayToken',
        ),
        relayEnabled: typed<bool>(
          companion,
          'relayEnabled',
          'companion.relayEnabled',
        ),
        extraRelays: extras == null
            ? null
            : [
                for (final value in extras as List)
                  _uri(
                    value is String ? value : null,
                    '$source: "companion.extraRelays"',
                  )!,
              ],
        notes: typed<bool>(companion, 'notes', 'companion.notes'),
        mcpPort: typed<int>(mcp, 'port', 'mcp.port'),
      ),
      source: source,
    );
  }

  static const _companionKeys = [
    'enabled',
    'bind',
    'port',
    'beacon',
    'relay',
    'relayToken',
    'relayEnabled',
    'extraRelays',
    'notes',
  ];

  static String _typeName<T>() => switch (T) {
    const (String) => 'string',
    const (bool) => 'true or false',
    const (int) => 'whole number',
    _ => '$T',
  };

  /// The flags `serve` and `init` take for these fields. Anything else in
  /// [args] is left alone — the caller's own flags. Throws
  /// [ServerConfigError] naming the flag.
  static ServerConfig fromFlags(List<String> args) {
    String? value(String flag) {
      String? found;
      for (final arg in args) {
        if (arg.startsWith('--$flag=')) found = arg.substring(flag.length + 3);
      }
      return found;
    }

    List<String> values(String flag) => [
      for (final arg in args)
        if (arg.startsWith('--$flag=')) arg.substring(flag.length + 3),
    ];

    int? port(String flag) {
      final text = value(flag);
      if (text == null) return null;
      final parsed = int.tryParse(text);
      if (parsed == null) {
        throw ServerConfigError('--$flag=$text is not a port number');
      }
      return parsed;
    }

    bool? toggle(String on, String off) {
      bool? said;
      for (final arg in args) {
        if (arg == '--$on') said = true;
        if (arg == '--$off') said = false;
      }
      return said;
    }

    final extras = values('extra-relay');
    return validated(
      ServerConfig(
        name: value('name'),
        companionEnabled: toggle('companion', 'no-companion'),
        bind: value('bind'),
        companionPort: port('companion-port'),
        beacon: toggle('beacon', 'no-beacon'),
        relay: _uri(value('relay'), '--relay'),
        relayToken: value('relay-token'),
        relayEnabled: toggle('relay-enabled', 'no-relay-enabled'),
        extraRelays: extras.isEmpty
            ? null
            : [for (final text in extras) _uri(text, '--extra-relay')!],
        notes: toggle('notes', 'no-notes'),
        mcpPort: port('mcp-port'),
      ),
      source: 'flags',
    );
  }

  /// [config], or a [ServerConfigError] naming what is wrong with it.
  static ServerConfig validated(ServerConfig config, {required String source}) {
    Never refuse(String why) => throw ServerConfigError('$source: $why');
    for (final (label, port) in [
      ('companion port', config.companionPort),
      ('MCP port', config.mcpPort),
    ]) {
      if (port != null && (port < 0 || port > 65535)) {
        refuse('the $label $port is not between 0 and 65535');
      }
    }
    final bind = config.bind;
    if (bind != null && InternetAddress.tryParse(bind) == null) {
      refuse('the bind address "$bind" is not an IP address');
    }
    final token = config.relayToken;
    if (token != null && !isUsableRelayToken(token)) {
      refuse('the relay token must be 32 or more url-safe characters');
    }
    if (token != null && config.relay == null) {
      refuse('a relay token needs a relay to go with it');
    }
    final name = config.name;
    if (name != null && name.trim().isEmpty) refuse('the name is empty');
    return config;
  }

  static Uri? _uri(String? text, String what) {
    if (text == null) return null;
    final parsed = Uri.tryParse(text.trim());
    if (parsed == null ||
        parsed.host.isEmpty ||
        !const {'ws', 'wss', 'http', 'https'}.contains(parsed.scheme)) {
      throw ServerConfigError(
        '$what: "$text" is not a relay URL (ws://, wss://, http:// or '
        'https:// and a host)',
      );
    }
    return parsed;
  }

  /// `<dataDirectory>/server.json`, or [empty] when there is none. Tightens
  /// a file others can read to owner-only first (it can hold the relay
  /// token), calling [log] to say so. Throws [ServerConfigError].
  static Future<ServerConfig> read(
    String dataDirectory, {
    void Function(String message)? log,
  }) async {
    final file = File(p.join(dataDirectory, kServerConfigFileName));
    if (!file.existsSync()) return empty;
    if (!Platform.isWindows && file.statSync().mode & 0x3f != 0) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        throw ServerConfigError(
          '${file.path} is readable by other accounts and could not be made '
          'owner-only: ${result.stderr}',
        );
      }
      log?.call('${file.path} was readable by other accounts; made owner-only');
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw ServerConfigError('${file.path}: not JSON (${error.message})');
    }
    return fromJson(json, source: file.path);
  }

  /// This with [patch] laid over it: [patch] is shaped like the file, a key
  /// it names replaces that field (inside `companion` and `mcp` too), a key
  /// set to null clears the field back to its default, and a key it leaves
  /// out is kept. Checked as the file is — throws [ServerConfigError] naming
  /// [source].
  ServerConfig patchedWith(
    Map<String, Object?> patch, {
    String source = 'server.config.set',
  }) {
    Map<String, Object?> merge(
      Map<String, Object?> base,
      Map<String, Object?> over,
    ) {
      final merged = Map<String, Object?>.of(base);
      for (final MapEntry(:key, :value) in over.entries) {
        final current = merged[key];
        if (value == null) {
          merged.remove(key);
        } else if (value is Map<String, Object?> &&
            current is Map<String, Object?>) {
          merged[key] = merge(current, value);
        } else {
          merged[key] = value;
        }
      }
      return merged;
    }

    final merged = merge(toJson(), patch);
    // An emptied section is no section: fromJson reads either the same.
    for (final section in const ['companion', 'mcp']) {
      final value = merged[section];
      if (value is Map && value.isEmpty) merged.remove(section);
    }
    return fromJson(merged, source: source);
  }

  /// Writes this as `<dataDirectory>/server.json`, owner-only from the first
  /// byte.
  Future<void> write(String dataDirectory) => writeOwnerOnly(
    p.join(dataDirectory, kServerConfigFileName),
    '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
  );
}

/// What a server runs by, every field decided: the file, overridden by the
/// flags, over the defaults.
class ServerSettings {
  const ServerSettings({
    required this.name,
    required this.bind,
    required this.companionPort,
    required this.mcpPort,
    required this.companion,
  });

  /// The address the phone listener binds when nothing says: loopback. A
  /// server may sit on a public address, and nobody has asked for phones to
  /// reach it yet — the desktop's Remote access switch, `init --bind` or the
  /// file says otherwise.
  static const String defaultBind = '127.0.0.1';

  /// Decides each field: a flag, else the file, else the default. Phones are
  /// not served until something turns the companion on (`companion.enabled`),
  /// and then on loopback unless `companion.bind` says otherwise.
  factory ServerSettings.resolve({
    required ServerConfig file,
    required ServerConfig flags,
    required String hostName,
  }) {
    final config = file.overriddenBy(flags);
    return ServerSettings(
      name: config.name?.trim() ?? hostName,
      bind: config.bind ?? defaultBind,
      companionPort: config.companionPort ?? kHostCompanionPort,
      mcpPort: config.mcpPort ?? kPreferredMcpPort,
      companion: companionConfigOf(config),
    );
  }

  final String name;
  final String bind;
  final int companionPort;
  final int mcpPort;

  /// How phones are served.
  final CompanionConfig companion;

  /// These settings as `server.config.get` reports them: every field decided.
  /// The relay is shown as configured, its token never.
  Map<String, Object?> toJson(ServerConfig decided) => {
    'name': name,
    'companion': {
      'enabled': companion.enabled,
      'bind': bind,
      'port': companionPort,
      'beacon': companion.advertise,
      'relay': ?decided.relay?.toString(),
      'relayTokenSet': decided.relayToken != null,
      'relayEnabled': decided.relayEnabled ?? true,
      'extraRelays': [for (final uri in companion.extraRelays) uri.toString()],
      'notes': companion.notesEnabled,
    },
    'mcp': {'port': mcpPort},
  };

  /// The companion's serving config [config] says: its relay, with the token
  /// spelled into the path the relay gates on (`/k/<token>`).
  static CompanionConfig companionConfigOf(ServerConfig config) {
    final relay = config.relay;
    final token = config.relayToken;
    final served = relay == null || token == null
        ? relay
        : relay.replace(
            path: joinRelayPath(relay.path, relayAccessTokenPrefix(token)),
          );
    return CompanionConfig(
      enabled: config.companionEnabled ?? false,
      relay: served,
      hostedEnabled: served != null && (config.relayEnabled ?? true),
      extraRelays: config.extraRelays ?? const [],
      notesEnabled: config.notes ?? true,
      advertise: config.beacon ?? false,
    );
  }
}
