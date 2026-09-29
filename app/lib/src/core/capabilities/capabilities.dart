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
    required this.hostsServer,
    required this.multicastLock,
    required this.mediaPlayback,
    required this.deviceName,
  });

  /// This process's platform, read once. [deviceModel] names a client that is
  /// not a desktop; a desktop is named by its hostname.
  factory ClientCapabilities.measure({String? deviceModel}) {
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
      hostsServer: desktop,
      multicastLock: !kIsWeb && Platform.isAndroid,
      mediaPlayback: desktop,
      deviceName: desktop ? _hostname() : _named(deviceModel),
    );
  }

  /// [measure], with [readModel] asked for the name only where the hostname
  /// is not one (a phone's is `localhost`).
  static Future<ClientCapabilities> measureNamed(
    Future<String?> Function() readModel,
  ) async {
    final measured = ClientCapabilities.measure();
    if (measured.hostsServer) return measured;
    return ClientCapabilities.measure(deviceModel: await readModel());
  }

  static String _hostname() {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? 'karmashala' : name;
  }

  static String _named(String? model) {
    final name = model?.trim() ?? '';
    return name.isEmpty ? 'Karmashala phone' : name;
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

  /// This client can run its own Karmashala server. Without it, no machine
  /// chosen leaves nothing to show but pairing.
  final bool hostsServer;

  /// Hearing the LAN beacon needs an OS multicast lock held.
  final bool multicastLock;

  /// media_kit has a backend here.
  final bool mediaPlayback;

  /// What this client is called at a server.
  final String deviceName;
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

  /// The Devices area, its dock and its settings: adb and simctl run here.
  bool get devicesArea => client.localDevices;

  /// Diagnostics › Server: starting and stopping the server on this machine.
  bool get serverSettings => server.sameMachine;

  /// Settings › Keyboard: the global hotkeys this client registers.
  bool get keyboardSettings => client.systemIntegration;

  /// "Pair a phone" and the server-side half of Remote: this client's own
  /// server is the one in use.
  bool get pairsHere => client.hostsServer && server.sameMachine;

  /// "This computer" is a machine to choose: this client can run the server.
  bool get hostsServer => client.hostsServer;

  /// A pane takes files dropped from the OS.
  bool get fileDrop => client.fileDrop;

  /// Administer the server: its config, devices, agents and pairings.
  bool get serverAdmin => server.granted(Capability.serverAdmin);

  /// A session's chat, an imported session's history and a subagent's turns
  /// are read by the server (`sessions.transcript`), on this machine or any
  /// other. Without it, only a server on this machine has a chat to show.
  bool get chatViaServer => serverOffers('sessions.transcript');

  /// The agent's rewind points, the files it changed and the question it has
  /// open are read by the server, where its record is (Stage 0 step 7).
  bool get rewindPointsViaServer => serverOffers('sessions.rewindPoints');
  bool get changedFilesViaServer => serverOffers('sessions.changedFiles');
  bool get openQuestionViaServer => serverOffers('sessions.openQuestion');

  /// An export, a recap and an imported session's seeded history quote the
  /// record's turns as the server reads them, text only (Stage 0 step 8).
  bool get turnsViaServer => serverOffers('sessions.transcript.turns');

  /// A session's counts and its agent's lifetime totals are read by the
  /// server, a list of sessions in one request (Stage 0 step 9).
  bool get statsViaServer => serverOffers('sessions.stats');

  /// A session's pictures are listed by the server, where its record is
  /// (Stage 0 step 10); their bytes come through `files.read` unless
  /// [readsServerDisk].
  bool get mediaViaServer => serverOffers('sessions.media');

  /// Chat sends, Stop and a deny's reason are typed by the server as host
  /// keys (Stage 2 step 2), so this client never takes the session's input
  /// or resizes its terminal to send.
  bool get sendViaServer =>
      serverOffers('sessions.send') && serverOffers('sessions.interrupt');

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
