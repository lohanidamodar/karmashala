import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/features/remote/application/remote_access_settings.dart';
import 'package:karmashala_host/server_config.dart';

/// The server's config held in memory — what `server.json` would say — so a
/// test never reads or writes the owner's real one. Every patch the app wrote
/// is kept in [patches].
class MemoryServerConfigSource implements ServerConfigSource {
  MemoryServerConfigSource([this.config = ServerConfig.empty]);

  ServerConfig config;
  final patches = <Map<String, Object?>>[];

  /// What the server says its LAN relay is doing, alongside every answer.
  LocalRelayReport localRelayReport = LocalRelayReport.unknown;

  @override
  Future<RemoteAccessSettings> read() async => _answer();

  @override
  Future<RemoteAccessSettings> write(Map<String, Object?> patch) async {
    patches.add(patch);
    config = config.patchedWith(patch);
    return _answer();
  }

  RemoteAccessSettings _answer() {
    final file = RemoteAccessSettings.fromConfig(config);
    return RemoteAccessSettings(
      enabled: file.enabled,
      relay: file.relay,
      relayEnabled: file.relayEnabled,
      extraRelays: file.extraRelays,
      localRelay: file.localRelay,
      localRelayPort: file.localRelayPort,
      localRelayReport: localRelayReport,
      notes: file.notes,
    );
  }
}

/// The override that puts [source] where the app reads its Remote access
/// settings from.
Override serverConfigIn(MemoryServerConfigSource source) =>
    serverConfigSourceProvider.overrideWithValue(source);

/// Sets the Remote access settings as the desktop's switches would: remote
/// access on or off, the internet relay's URL (empty: PopupBits'), and whether
/// that relay is served. Straight into the config, without the controller's
/// sync, so a test drives that itself.
Future<void> setRemoteAccess(
  ProviderContainer container, {
  bool? enabled,
  String? relayUrl,
  bool? hostedEnabled,
}) => container.read(remoteAccessSettingsProvider.notifier).update({
  'companion': {
    'enabled': ?enabled,
    if (relayUrl != null)
      'relay': relayUrl.trim().isEmpty ? null : relayUrl.trim(),
    'relayEnabled': ?hostedEnabled,
  },
});

/// [setRemoteAccess] at once, without the server config: what the app knows
/// is replaced — the server's local relay and its report among it — and
/// nothing is written anywhere.
void setRemoteAccessNow(
  ProviderContainer container, {
  bool? enabled,
  String? relayUrl,
  bool? hostedEnabled,
  bool? localRelay,
  LocalRelayReport? localRelayReport,
}) {
  final current = container.read(remoteAccessSettingsProvider);
  final relay = relayUrl?.trim();
  container
      .read(remoteAccessSettingsProvider.notifier)
      .debugReplace(
        RemoteAccessSettings(
          enabled: enabled ?? current.enabled,
          relay: relay == null
              ? current.relay
              : (relay.isEmpty ? null : Uri.parse(relay)),
          relayEnabled: hostedEnabled ?? current.relayEnabled,
          extraRelays: current.extraRelays,
          localRelay: localRelay ?? current.localRelay,
          localRelayPort: current.localRelayPort,
          localRelayReport: localRelayReport ?? current.localRelayReport,
          notes: current.notes,
        ),
      );
}
