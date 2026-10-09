import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ProjectFoldersCreate;
import 'package:karmashala_remote/remote.dart'
    show AttachTier, Capability, CapabilitySet;
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
    required this.localNotifications,
    required this.localDevices,
    required this.externalApps,
    required this.fileDrop,
    required this.relaunch,
    required this.density,
    required this.hostsServer,
    required this.multicastLock,
    required this.mediaPlayback,
    required this.deviceName,
    required this.camera,
  });

  /// This process's platform, read once. [deviceModel] names a client that is
  /// not a desktop; a desktop is named by its hostname.
  factory ClientCapabilities.measure({String? deviceModel}) {
    final desktop =
        !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return ClientCapabilities(
      systemIntegration: desktop,
      osToasts: desktop,
      localNotifications: mobile,
      localDevices: desktop,
      externalApps: desktop,
      fileDrop: desktop,
      relaunch: desktop,
      density: UiDensity.forPlatform(defaultTargetPlatform),
      hostsServer: desktop,
      multicastLock: !kIsWeb && Platform.isAndroid,
      mediaPlayback: desktop,
      deviceName: desktop ? _hostname() : _named(deviceModel),
      camera: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
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

  /// A phone's notifications (`flutter_local_notifications`), shown while the
  /// app's process runs; there is no push (Stage 3 step 2).
  final bool localNotifications;

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

  /// A photo can be taken here (`image_picker`'s camera source).
  final bool camera;
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

  /// Whether a phone's pairing grants [capability] (Stage 3 step 3). Only a
  /// phone-tier link is narrowed: a desktop client's pairing names none of
  /// these bits, and may do all a desktop does.
  bool phoneGranted(Capability capability) {
    final grants = this.grants;
    return grants == null ||
        grants.attachTier != AttachTier.phone ||
        grants.has(capability);
  }
}

/// The companion's words for a phone refused by its grants.
const kPromptNotGranted = 'This phone was not granted prompt rights.';
const kApprovalNotGranted =
    'This phone was not granted approval rights, so it cannot answer. '
    'Answer in its terminal.';
const kStartNotGranted =
    'This phone was not granted permission to start sessions.';
const kAddProjectNotGranted =
    'This phone was not granted permission to add projects.';
const kUsageNotGranted = 'Usage was not granted to this phone.';

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

  /// A phone's notifications, one per session, with settings kept on the
  /// device rather than at the server.
  bool get localNotifications => client.localNotifications;

  /// Settings › Notifications, and agent news turned into notifications here.
  bool get notifiesHere => client.osToasts || client.localNotifications;

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

  /// New session offers "External terminal": a terminal window this client
  /// opens, which a phone has none of.
  bool get externalTerminalSessions => client.externalApps;

  /// A pane takes files dropped from the OS.
  bool get fileDrop => client.fileDrop;

  /// Administer the server: its config, devices, agents and pairings.
  bool get serverAdmin => server.granted(Capability.serverAdmin);

  /// A phone's grants, mirrored so it never offers what the server refuses.
  /// The terminal is never gated: these guard against a slip, not a thief.
  bool get mayApprove => server.phoneGranted(Capability.approve);
  bool get maySend => server.phoneGranted(Capability.sendPrompt);
  bool get mayStart => server.phoneGranted(Capability.startSession);
  bool get mayAttach => server.phoneGranted(Capability.sendAttachment);
  bool get mayAddProject => server.phoneGranted(Capability.addProject);
  bool get mayViewUsage => server.phoneGranted(Capability.viewUsage);

  /// A session's chat, an imported session's history and a subagent's turns
  /// are read by the server (`sessions.transcript`), on this machine or any
  /// other. Without it, only a server on this machine has a chat to show.
  bool get chatViaServer => serverOffers('sessions.transcript');

  /// A background agent's turns are read by the server by the agent's id,
  /// for a run whose row names no file for it.
  bool get subagentByAgentId =>
      serverOffers('sessions.transcript.subagent.agentId');

  /// The agent's rewind points, the files it changed and the question it has
  /// open are read by the server, where its record is (Stage 0 step 7).
  bool get rewindPointsViaServer => serverOffers('sessions.rewindPoints');

  /// A session can be rewound to before one of the person's messages
  /// (`sessions.rewind`, round 64).
  bool get rewindViaServer => serverOffers('sessions.rewind');
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

  /// The server runs ACP agents as sessions of its own and serves their
  /// conversation from its rows; without it the New Session
  /// dialog offers none.
  bool get acpSessions => serverOffers('acpSessions');

  /// An approval names the prompt it answers, and the server refuses it when
  /// another is open by the time it lands (Stage 2 step 1).
  bool get answersCarryAsk => serverOffers('prompt.answer.ask');

  /// Chat sends, Stop and a deny's reason are typed by the server as host
  /// keys (Stage 2 step 2), so this client never takes the session's input
  /// or resizes its terminal to send.
  bool get sendViaServer =>
      serverOffers('sessions.send') && serverOffers('sessions.interrupt');

  /// A send the server refuses for a session it does not hold may be typed
  /// into a pane here. Not from another machine: every pane there is a view
  /// of the server's own terminal, so typing into it loses the message.
  bool get typesIntoOwnPanes => server.sameMachine;

  /// A send to an ACP session nothing runs is resumed by the server itself,
  /// so this client sends and asks for no resume of its own.
  bool get sendResumesAtServer =>
      sendViaServer && serverOffers('sessions.send.resumes');

  /// A send while the turn runs waits at the server, shown as queued with
  /// edit and cancel; without it, nothing is listed.
  bool get sessionQueue => sendViaServer && serverOffers('sessions.queue');

  /// The server holds launches to a person's concurrency limits, says who
  /// waits for a slot, and starts or cancels a wait.
  bool get sessionCapacity => serverOffers('sessions.capacity');

  /// The queue says what holds it, pauses on Stop, and takes Send next.
  bool get sessionQueueControl =>
      sessionQueue && serverOffers('sessions.queue.control');

  /// One queued message or all of them sent now, and the queue paused at a
  /// person's word.
  bool get sessionQueueManage =>
      sessionQueueControl && serverOffers('sessions.queue.manage');

  /// A session's agent can be switched in place, the same row and chat, and
  /// its transcript names the agent of each turn.
  bool get switchAgent => serverOffers('sessions.switchAgent');

  /// A sub-session can be detached from its parent, and a phone may do it
  /// where it may start sessions.
  bool get detachSessions => serverOffers('sessions.detach') && mayStart;

  /// A top-level session can be attached under a parent, where a phone may
  /// start sessions.
  bool get attachSessions => serverOffers('sessions.attach') && mayStart;

  /// New Project can make a missing folder and record a root without a scan;
  /// an older server ignores both and scans.
  bool get createsProjectFolders => serverOffers(ProjectFoldersCreate.feature);

  /// Terminals lists every shell the server runs and opens the server's own
  /// shell (Stage 2 step 11). A phone only: a desktop's area is unchanged.
  bool get serverTerminalsArea => !client.hostsServer && !server.sameMachine;

  /// Attach offers "Take a photo": a camera here, a server elsewhere to
  /// upload it to, and [mayAttach]: the camera row shows exactly when Attach
  /// does, before the first `host.status` too.
  bool get takesPhotos => client.camera && uploads && mayAttach;

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
