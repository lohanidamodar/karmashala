import 'server_config.dart';

/// The server's config while it runs: `server.json` as last read or written,
/// the `serve` flags over it, and what they decide. `server.config.get` reads
/// it; `server.config.set` patches the file — owner-only, as `init` writes it
/// — and hands the decided settings to [apply], which brings the phone
/// listener in line at once. The file is the one source: nothing else keeps
/// a copy of how phones are served.
class ServerConfigService {
  ServerConfigService({
    required this.dataDirectory,
    required ServerConfig file,
    required this.flags,
    required this.hostName,
    this.apply,
  }) : _file = file,
       _settings = ServerSettings.resolve(
         file: file,
         flags: flags,
         hostName: hostName,
       );

  /// Where `server.json` lives.
  final String dataDirectory;

  /// The `serve` flags: each overrides its field of the file for the life of
  /// the process, so a set that writes one is kept but not what is served.
  final ServerConfig flags;

  /// What the server is called when nothing names it.
  final String hostName;

  /// Brings the running server in line with new settings. Where to bind and
  /// how to serve apply at once; the name and the MCP port at the next start.
  Future<void> Function(ServerSettings settings)? apply;

  ServerConfig _file;
  ServerSettings _settings;
  Future<void> _chain = Future<void>.value();

  /// `server.json` as it stands.
  ServerConfig get file => _file;

  /// What the server runs by now.
  ServerSettings get settings => _settings;

  /// `{file, settings}`: the file as written (its relay token never — only
  /// whether one is set) and every field decided.
  Map<String, Object?> describe() => {
    'file': _redacted(_file).toJson(),
    'settings': _settings.toJson(_file.overriddenBy(flags)),
    'flags': [
      for (final MapEntry(:key) in flags.toJson().entries)
        if (key != 'companion' && key != 'mcp') key,
      for (final key in _sectionKeys(flags.toJson(), 'companion'))
        'companion.$key',
      for (final key in _sectionKeys(flags.toJson(), 'mcp')) 'mcp.$key',
    ],
  };

  /// Lays [patch] over the file, writes it owner-only and applies it. Throws
  /// [ServerConfigError] naming what is wrong, with nothing written.
  Future<Map<String, Object?>> set(Map<String, Object?> patch) {
    final done = _chain.then((_) async {
      final next = _file.patchedWith(patch);
      await next.write(dataDirectory);
      _file = next;
      _settings = ServerSettings.resolve(
        file: next,
        flags: flags,
        hostName: hostName,
      );
      await apply?.call(_settings);
      return describe();
    });
    _chain = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  static Iterable<String> _sectionKeys(
    Map<String, Object?> json,
    String section,
  ) {
    final value = json[section];
    return value is Map<String, Object?> ? value.keys : const [];
  }

  static ServerConfig _redacted(ServerConfig config) => ServerConfig(
    name: config.name,
    companionEnabled: config.companionEnabled,
    bind: config.bind,
    companionPort: config.companionPort,
    beacon: config.beacon,
    relay: config.relay,
    relayEnabled: config.relayEnabled,
    extraRelays: config.extraRelays,
    localRelay: config.localRelay,
    localRelayPort: config.localRelayPort,
    notes: config.notes,
    mcpPort: config.mcpPort,
  );
}
