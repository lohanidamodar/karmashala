import 'package:flutter/foundation.dart';
import 'package:karmashala_core/logging.dart' show appVersion;
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show SessionSummary;
import 'package:karmashala_terminal_runtime/host_link.dart'
    show HostSupervision, HostSupervisionPhase, SharedHostLinks;
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_client.dart' show DataLinkState;
import '../../../core/data/data_providers.dart';
import '../../../core/logging/diagnostics_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../terminal/application/local_host_providers.dart';

enum ServerRunState {
  running('Running'),
  starting('Starting…'),
  stopped('Stopped'),
  unknown('Not checked');

  const ServerRunState(this.label);
  final String label;
}

/// What Settings → Server says about a server: this machine's on a desktop,
/// the one it is connected to on a phone. Every reading may be missing, and a
/// missing one is said as such rather than as zero.
@immutable
class ServerOverview {
  const ServerOverview({
    required this.state,
    required this.appVersion,
    this.serverVersion,
    this.startedAt,
    this.liveSessions,
    this.endedSessions,
    this.dataFolder,
    this.socketPath,
    this.controlsRefusal,
    this.canRestart = true,
    this.canStop = true,
  });

  final ServerRunState state;
  final String appVersion;
  final String? serverVersion;
  final DateTime? startedAt;
  final int? liveSessions;
  final int? endedSessions;
  final String? dataFolder;
  final String? socketPath;

  /// Why Restart and Stop cannot act from this window, or null when they can.
  final String? controlsRefusal;
  final bool canRestart;
  final bool canStop;

  bool get versionsDiffer =>
      serverVersion != null &&
      appVersion.isNotEmpty &&
      serverVersion != appVersion;
}

/// How long a server has been up, to the two largest units.
String describeUptime(Duration up) {
  if (up.inMinutes < 1) return 'under a minute';
  if (up.inHours < 1) return '${up.inMinutes}m';
  if (up.inDays < 1) return '${up.inHours}h ${up.inMinutes % 60}m';
  return '${up.inDays}d ${up.inHours % 24}h';
}

/// "2 running · 5 ended", or null when the server would not say.
String? describeSessionsHeld(ServerOverview overview) {
  final live = overview.liveSessions;
  final ended = overview.endedSessions;
  if (live == null || ended == null) return null;
  return '$live running · $ended ended';
}

/// This machine's server as [reading] and [supervision] have it. Lists the
/// host's sessions only when it answers, so a stuck host is not asked again.
Future<ServerOverview> localServerOverview({
  required HostDeployment? reading,
  required HostSupervision? supervision,
  required Future<List<SessionSummary>> Function()? listSessions,
  DateTime? startedAt,
  String? dataFolder,
  String? socketPath,
  String? controlsRefusal,
  String version = appVersion,
}) async {
  final phase = supervision?.phase;
  final state = switch (reading) {
    _
        when phase == HostSupervisionPhase.starting ||
            phase == HostSupervisionPhase.restarting =>
      ServerRunState.starting,
    _ when phase == HostSupervisionPhase.stopped => ServerRunState.stopped,
    null => ServerRunState.unknown,
    final r when r.isReady => ServerRunState.running,
    final r when r.hostUnresponsive => ServerRunState.running,
    _ => ServerRunState.stopped,
  };
  int? live;
  int? ended;
  if (reading != null && reading.isReady && listSessions != null) {
    try {
      final sessions = await listSessions();
      ended = sessions.where((s) => s.lifecycle.hasEnded).length;
      live = sessions.length - ended;
    } on Object {
      // Would not say: both stay unknown.
    }
  }
  // An older host that speaks another protocol still said what it runs.
  live ??= reading?.liveSessionIds?.length;
  final answers = reading != null && reading.isReady;
  return ServerOverview(
    state: state,
    appVersion: version,
    serverVersion: reading?.hostVersion,
    startedAt: answers ? startedAt : null,
    liveSessions: live,
    endedSessions: ended,
    dataFolder: dataFolder,
    socketPath: socketPath,
    controlsRefusal: controlsRefusal,
    canRestart:
        answers ||
        (reading?.hostUnresponsive ?? false) ||
        (reading?.hostOutdated ?? false),
    canStop: answers || (reading?.hostOutdated ?? false),
  );
}

/// The reading Settings → Server draws. Rebuilt when the host's status or
/// supervision changes; reads nothing on a timer.
final serverOverviewProvider = FutureProvider<ServerOverview>((ref) async {
  final caps = ref.watch(capabilitiesProvider);
  if (!caps.hostsServer) return _connectedServerOverview(ref);

  final access = ref.watch(localHostSessionAccessProvider);
  final reading = ref.watch(localHostStatusProvider);
  final supervision = ref.watch(localHostSupervisionProvider).value;
  final welcome = access == null
      ? null
      : SharedHostLinks.current(access)?.welcome;
  String? dataFolder;
  try {
    dataFolder = (await ref.watch(
      localServerDataDirectoryProvider.future,
    )).path;
  } on Object {
    dataFolder = null;
  }
  return localServerOverview(
    reading: reading,
    supervision: supervision,
    listSessions: access?.listSessions,
    // The welcome's start time is this host's only if it is the same process.
    startedAt: welcome != null && welcome.pid == reading?.hostPid
        ? welcome.startedAt
        : null,
    dataFolder: dataFolder,
    socketPath: access?.socketPath,
    controlsRefusal: !caps.serverSettings
        ? 'This window is connected to a server on another machine, so this '
              'app is not the one running this machine\'s server.'
        : access == null
        ? 'This app cannot reach a server on this machine.'
        : null,
  );
});

/// A phone's summary of the server it is connected to: whether the link is
/// up, the version it said hello with, and the sessions it keeps.
ServerOverview _connectedServerOverview(Ref ref) {
  final access = ref.watch(serverAccessProvider);
  // A new link says hello with its own version and start time.
  ref.watch(serverOfferProvider);
  final welcome = access == null
      ? null
      : SharedHostLinks.current(access)?.welcome;
  final link = ref.watch(dataConnectionProvider).value?.state;
  final sessions = ref.watch(sessionsDataProvider).getAll();
  return ServerOverview(
    state: switch (link) {
      DataLinkState.connected => ServerRunState.running,
      DataLinkState.connecting => ServerRunState.starting,
      null => ServerRunState.unknown,
      _ => ServerRunState.stopped,
    },
    appVersion: appVersion,
    serverVersion: welcome?.hostVersion,
    startedAt: welcome?.startedAt,
    liveSessions: sessions.where((s) => s.status.claimsLive).length,
    endedSessions: sessions.where((s) => s.status.isEnded).length,
    controlsRefusal: 'Restart and Stop are on the server\'s own machine.',
    canRestart: false,
    canStop: false,
  );
}
