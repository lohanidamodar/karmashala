import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;
import 'package:karmashala_ui/tokens.dart' show UiDensity;
import 'package:riverpod/riverpod.dart';

import '../../features/terminal/application/local_host_providers.dart'
    show serverAccessProvider;
import '../data/data_providers.dart';
import '../server/remote_server_access.dart';

/// What this client can do by itself, whatever server it is attached to.
/// Measured once (spec §3.2).
@immutable
final class ClientCapabilities {
  const ClientCapabilities({
    required this.systemIntegration,
    required this.osToasts,
    required this.localDevices,
    required this.externalApps,
    required this.fileDrop,
    required this.relaunch,
    required this.density,
  });

  /// This process's platform, read once.
  factory ClientCapabilities.measure() {
    final desktop =
        !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    return ClientCapabilities(
      systemIntegration: desktop,
      osToasts: desktop,
      localDevices: desktop,
      externalApps: desktop,
      fileDrop: desktop,
      relaunch: desktop,
      density: UiDensity.forPlatform(defaultTargetPlatform),
    );
  }

  /// Tray, window chrome, hotkeys, launch at login.
  final bool systemIntegration;

  /// OS notifications (`local_notifier`).
  final bool osToasts;

  /// adb and simctl run on this machine.
  final bool localDevices;

  /// External editors, terminals and a file manager to reveal in.
  final bool externalApps;

  /// Files dropped from the OS onto the window.
  final bool fileDrop;

  /// The app can restart itself.
  final bool relaunch;
  final UiDensity density;
}

/// What the attached server offers this client.
@immutable
final class ServerOffer {
  const ServerOffer({
    required this.sameMachine,
    this.grants,
    this.serverOs,
    this.features = const {},
  });

  /// The server runs on this client's machine, so its disk is this one's.
  final bool sameMachine;

  /// What the server granted this client (`host.status`); null on a local
  /// link, which may do everything (`LinkTrust.local`). The server enforces
  /// grants; the client only mirrors them.
  final CapabilitySet? grants;

  /// `welcome.operatingSystem` (this machine's own when [sameMachine]); null
  /// for a server elsewhere until its link has said hello.
  final String? serverOs;

  /// `welcome.features`: what the server serves beyond the protocol number.
  final Set<String> features;

  bool granted(Capability capability) => grants?.has(capability) ?? true;
}

/// **The one question a surface asks** before it shows itself (spec §3.2):
/// never `Platform`, `serverOnThisMachine` or width. Each getter is named for
/// the surface or act it gates; add one per new gate rather than reading
/// [client] or [server] at the call site.
@immutable
final class Capabilities {
  const Capabilities({required this.client, required this.server});

  final ClientCapabilities client;
  final ServerOffer server;

  /// A path the server spells is a path on this machine: it opens in a local
  /// program, is revealed in the file manager, or is dropped as text.
  bool get readsServerDisk => server.sameMachine;

  /// A file from this machine reaches the server only by upload.
  bool get uploads => !server.sameMachine;

  /// This app sets up the server's machine as its own: discovers its
  /// environments and agents, installs agent hooks and skills, imports CLI
  /// sessions, repairs agent paths and starts the local session host.
  bool get setsUpThisMachine => server.sameMachine;

  /// The server's device claims are about this machine's devices.
  bool get sharesDevices => client.localDevices && server.sameMachine;

  /// Paths the server spells are Windows paths.
  bool get serverOnWindows => server.serverOs == 'windows';

  bool get systemIntegration => client.systemIntegration;

  bool get osToasts => client.osToasts;

  /// Administer the server: its config, devices, agents and pairings.
  bool get serverAdmin => server.granted(Capability.serverAdmin);

  /// A session's chat, an imported session's history and a subagent's turns
  /// are read by the server (`sessions.transcript`), on this machine or any
  /// other. Without it, only a server on this machine has a chat to show.
  bool get chatViaServer => serverOffers('sessions.transcript');

  /// Whether the server announced [feature] in its welcome.
  bool serverOffers(String feature) => server.features.contains(feature);
}

final clientCapabilitiesProvider = Provider<ClientCapabilities>(
  (ref) => ClientCapabilities.measure(),
);

/// Rebuilt when a new link says hello, and when a remote server's grants
/// change at a redial.
final serverOfferProvider = Provider<ServerOffer>((ref) {
  final sameMachine = ref.watch(dataClientProvider).serverOnThisMachine;
  final access = ref.watch(serverAccessProvider);
  if (access == null) {
    return ServerOffer(
      sameMachine: sameMachine,
      serverOs: sameMachine ? Platform.operatingSystem : null,
    );
  }
  final opened = SharedHostLinks.opened(
    access,
  ).listen((_) => ref.invalidateSelf());
  ref.onDispose(opened.cancel);
  CapabilitySet? grants;
  if (access is RemoteServerAccess) {
    final source = access.grants;
    void changed() => ref.invalidateSelf();
    source.addListener(changed);
    ref.onDispose(() => source.removeListener(changed));
    grants = source.value ?? CapabilitySet.none;
  }
  final welcome = SharedHostLinks.current(access)?.welcome;
  return ServerOffer(
    sameMachine: sameMachine,
    grants: grants,
    serverOs:
        welcome?.operatingSystem ??
        (sameMachine ? Platform.operatingSystem : null),
    features: welcome?.features ?? const {},
  );
});

/// Read it with `ref.watch` in a build, so a surface follows a grant or a
/// server that changes.
final capabilitiesProvider = Provider<Capabilities>(
  (ref) => Capabilities(
    client: ref.watch(clientCapabilitiesProvider),
    server: ref.watch(serverOfferProvider),
  ),
);
