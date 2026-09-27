/// The desktop's Remote access settings, whose one source is this machine's
/// server config (`<server data dir>/server.json`): read and written through
/// the server (`server.config.get` / `server.config.set`) while it serves the
/// phones, and straight in the file only where no server runs. The app keeps
/// no copy of its own.
library;

import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ServerMethod;
import 'package:karmashala_host/server_config.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/paths/server_data_directory.dart';
import 'host_companion_link.dart';
import 'host_companion_providers.dart';

/// What the server's own LAN relay is doing, as `server.config.get` tells
/// it (`localRelay`): the settings row and the pairing dialog's "Local
/// network" tab read it. The relay is the server's; the app only shows it.
class LocalRelayReport {
  const LocalRelayReport({
    this.state = LocalRelayRunState.stopped,
    this.url,
    this.port,
    this.otherUrls = const [],
    this.error,
    this.firewallHint = false,
  });

  /// Nothing told: a server that was not asked, or the file read directly.
  static const LocalRelayReport unknown = LocalRelayReport(
    state: LocalRelayRunState.unknown,
  );

  final LocalRelayRunState state;

  /// The address a phone should dial, when the server has one.
  final Uri? url;
  final int? port;

  /// The other addresses it can be dialled on.
  final List<Uri> otherUrls;

  /// Why it is not running — e.g. the port is taken.
  final String? error;

  /// The server could not add its firewall rule (Windows, no admin).
  final bool firewallHint;

  bool get running => state == LocalRelayRunState.running;

  factory LocalRelayReport.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return unknown;
    Uri? uri(Object? value) => value is String ? Uri.tryParse(value) : null;
    final endpoints = json['endpoints'];
    return LocalRelayReport(
      state: switch (json['state']) {
        'running' => LocalRelayRunState.running,
        'error' => LocalRelayRunState.error,
        'stopped' => LocalRelayRunState.stopped,
        _ => LocalRelayRunState.unknown,
      },
      url: uri(json['url']),
      port: json['port'] is int ? json['port']! as int : null,
      otherUrls: [
        for (final endpoint in endpoints is List ? endpoints : const [])
          if (endpoint is Map<String, Object?> && endpoint['primary'] != true)
            ?uri(endpoint['url']),
      ],
      error: json['error'] is String ? json['error']! as String : null,
      firewallHint: json['firewallHint'] == true,
    );
  }
}

enum LocalRelayRunState { unknown, stopped, running, error }

/// The port the server's LAN relay binds unless the config moves it — the
/// relay's own default, which the server decides too.
const int kLocalRelayPortDefault = 8787;

/// How this machine's server serves phones, as its config decides it.
class RemoteAccessSettings {
  const RemoteAccessSettings({
    required this.enabled,
    this.relay,
    this.relayEnabled = true,
    this.extraRelays = const [],
    this.localRelay = false,
    this.localRelayPort = kLocalRelayPortDefault,
    this.localRelayReport = LocalRelayReport.unknown,
    this.notes = true,
    this.loaded = true,
  });

  /// Nothing read yet: shown as off, and never written back as if it were
  /// what the server says.
  static const RemoteAccessSettings unknown = RemoteAccessSettings(
    enabled: false,
    loaded: false,
  );

  /// Whether phones are served at all (`companion.enabled`).
  final bool enabled;

  /// The internet relay as configured, or null for none — the desktop shows
  /// the PopupBits relay then.
  final Uri? relay;

  /// Whether [relay] is served (`companion.relayEnabled`); off parks it.
  final bool relayEnabled;

  /// The relays on this person's SSH hosts the server listens on too.
  final List<Uri> extraRelays;

  /// Whether the server runs its own LAN relay (`companion.localRelay`), and
  /// on which port.
  final bool localRelay;
  final int localRelayPort;

  /// What that relay is doing, as the server last said.
  final LocalRelayReport localRelayReport;

  /// Whether a phone's `notes.get` answers.
  final bool notes;

  /// Whether this came from the server's config, rather than [unknown].
  final bool loaded;

  /// From `server.config.get`'s `settings` — every field decided — and its
  /// `localRelay` report.
  factory RemoteAccessSettings.fromSettings(
    Map<String, Object?> settings, {
    Object? localRelayReport,
  }) {
    final companion = settings['companion'];
    final json = companion is Map<String, Object?>
        ? companion
        : const <String, Object?>{};
    Uri? uri(Object? value) => value is String ? Uri.tryParse(value) : null;
    final extras = json['extraRelays'];
    return RemoteAccessSettings(
      enabled: json['enabled'] == true,
      relay: uri(json['relay']),
      relayEnabled: json['relayEnabled'] != false,
      extraRelays: [
        for (final value in extras is List ? extras : const []) ?uri(value),
      ],
      localRelay: json['localRelay'] == true,
      localRelayPort: json['localRelayPort'] is int
          ? json['localRelayPort']! as int
          : kLocalRelayPortDefault,
      localRelayReport: LocalRelayReport.fromJson(localRelayReport),
      notes: json['notes'] != false,
    );
  }

  /// From the file itself, where no server answers: its defaults decided the
  /// way the server decides them.
  factory RemoteAccessSettings.fromConfig(ServerConfig config) =>
      RemoteAccessSettings(
        enabled: config.companionEnabled ?? false,
        relay: config.relay,
        relayEnabled: config.relayEnabled ?? true,
        extraRelays: config.extraRelays ?? const [],
        localRelay: config.localRelay ?? false,
        localRelayPort: config.localRelayPort ?? kLocalRelayPortDefault,
        notes: config.notes ?? true,
      );
}

/// Where the settings are read from and written to.
abstract interface class ServerConfigSource {
  Future<RemoteAccessSettings> read();

  /// Lays [patch] — shaped like `server.json`, a null clearing a field — over
  /// the config and answers what it decides now. Throws with the reason when
  /// it is refused.
  Future<RemoteAccessSettings> write(Map<String, Object?> patch);
}

/// Through the server on this machine, over the app's lifecycle link: it
/// writes the file owner-only and applies it to the phone listener at once.
class HostServerConfigSource implements ServerConfigSource {
  HostServerConfigSource(this._link);

  final HostCompanionLink _link;

  @override
  Future<RemoteAccessSettings> read() async =>
      _settingsOf(await _link.serverCall(ServerMethod.configGet));

  @override
  Future<RemoteAccessSettings> write(Map<String, Object?> patch) async =>
      _settingsOf(
        await _link.serverCall(ServerMethod.configSet, {'patch': patch}),
      );

  static RemoteAccessSettings _settingsOf(Map<String, Object?> answer) {
    final settings = answer['settings'];
    return RemoteAccessSettings.fromSettings(
      settings is Map<String, Object?> ? settings : const {},
      localRelayReport: answer['localRelay'],
    );
  }
}

/// The file itself, where no local server may be reached: the server serves
/// by it from its next start.
class FileServerConfigSource implements ServerConfigSource {
  FileServerConfigSource(this._dataDirectory);

  final Future<Directory> Function() _dataDirectory;

  @override
  Future<RemoteAccessSettings> read() async => RemoteAccessSettings.fromConfig(
    await ServerConfig.read((await _dataDirectory()).path),
  );

  @override
  Future<RemoteAccessSettings> write(Map<String, Object?> patch) async {
    final directory = (await _dataDirectory()).path;
    final next = (await ServerConfig.read(directory)).patchedWith(patch);
    await next.write(directory);
    return RemoteAccessSettings.fromConfig(next);
  }
}

/// Where this app reads and writes them: the server while it serves the
/// phones, else the file.
final serverConfigSourceProvider = Provider<ServerConfigSource>(
  (ref) => ref.watch(companionAtHostProvider)
      ? HostServerConfigSource(ref.watch(hostCompanionLinkProvider))
      : FileServerConfigSource(serverDataDirectory),
);

/// The settings as last read from, or written to, the server's config.
class RemoteAccessSettingsController extends Notifier<RemoteAccessSettings> {
  static final _log = AppLogger.named('remote.settings');

  @override
  RemoteAccessSettings build() => RemoteAccessSettings.unknown;

  /// Reads them again. A server that cannot be asked yet leaves them as they
  /// were: the link attaching asks again.
  Future<void> load() async {
    try {
      state = await ref.read(serverConfigSourceProvider).read();
    } on Object catch (error) {
      _log.info('Remote access settings not read yet: $error');
    }
  }

  /// Writes [patch] and takes what the server decided. Throws with the
  /// server's reason when it refuses; nothing changes then.
  Future<void> update(Map<String, Object?> patch) async {
    state = await ref.read(serverConfigSourceProvider).write(patch);
  }

  /// Replaces what is known without asking the server: for a test standing
  /// in for it.
  void debugReplace(RemoteAccessSettings settings) => state = settings;
}

final remoteAccessSettingsProvider =
    NotifierProvider<RemoteAccessSettingsController, RemoteAccessSettings>(
      RemoteAccessSettingsController.new,
    );
