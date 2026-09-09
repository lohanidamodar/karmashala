/// Riverpod bridges from the [CompanionGateway] streams to the phone UI.
library;

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';

/// The gateway the companion UI reads.
///
/// The package owns the interface and both implementations; the provider over
/// them is the app's wiring, so it stays here. Defaults to an unpaired
/// [FakeCompanionGateway] so companion mode boots to the pairing screen with
/// no host wired; the orchestrator overrides this with the real client at
/// integration.
final companionGatewayProvider = Provider<CompanionGateway>(
  (ref) => FakeCompanionGateway(),
);

/// The pairing in effect, or null when this phone has never paired.
final companionPairingProvider = StreamProvider<CompanionPairing?>(
  (ref) => ref.watch(companionGatewayProvider).pairingStates,
);

/// Whether the phone can currently reach the host.
final companionLinkProvider = StreamProvider<CompanionLinkState>(
  (ref) => ref.watch(companionGatewayProvider).linkStates,
);

/// Why the link is not up, when the gateway has learned anything more exact
/// than "connecting". Its own provider on purpose: the reason is learned by a
/// dial that failed while the phone was already `connecting`, so there is no
/// link-state change under it, and a surface that only re-reads the getter on
/// rebuild shows a bare "Connecting…" for the whole first pass.
final companionLinkTroubleProvider = StreamProvider<String?>(
  (ref) => ref.watch(companionGatewayProvider).linkTroubleStates,
);

/// Every desktop this phone has paired with, one of them active.
final companionConnectionsProvider =
    StreamProvider<List<CompanionConnection>>(
      (ref) => ref.watch(companionGatewayProvider).connectionsStates,
    );

/// Drives [CompanionGateway.switchTo] / [CompanionGateway.removeConnection],
/// holding the host id whose switch is in flight so every surface that offers
/// the verb shows the same progress and the same refusal.
class CompanionSwitcher extends Notifier<String?> {
  @override
  String? build() => null;

  /// The last refusal, for a surface that wants to show it. Cleared when the
  /// next attempt starts.
  String? lastError;

  Future<void> switchTo(String hostId) =>
      _run(hostId, () => ref.read(companionGatewayProvider).switchTo(hostId));

  Future<void> remove(String hostId) => _run(
    hostId,
    () => ref.read(companionGatewayProvider).removeConnection(hostId),
  );

  Future<void> _run(String hostId, Future<void> Function() action) async {
    // One switch at a time: a second tap mid-flight would tear down a link
    // that is still coming up.
    if (state != null) return;
    lastError = null;
    state = hostId;
    try {
      await action();
    } on GatewayException catch (error) {
      lastError = error.message;
    } on Object {
      // Nothing may escape into an unhandled async error: the surfaces that
      // offer these verbs show `lastError` and nothing else, so a refusal
      // that gets past here is a tap that visibly did nothing.
      lastError = 'That could not be done just now. Try again.';
    } finally {
      state = null;
    }
  }
}

/// The host id a switch is currently in flight for, or null.
final companionSwitchingProvider =
    NotifierProvider<CompanionSwitcher, String?>(CompanionSwitcher.new);

/// Which path carries the link — Direct (LAN) or Relay — or null while down.
final companionLinkPathProvider = StreamProvider<CompanionLinkPath?>(
  (ref) => ref.watch(companionGatewayProvider).linkPathStates,
);

/// When the link last changed state, so a surface can carry the age of what it
/// claims (CLAUDE.md §19). Null until this phone has observed a change: an
/// unstamped reading must say so rather than read "just now".
final companionLinkSinceProvider = StreamProvider<DateTime?>(
  (ref) => ref.watch(companionGatewayProvider).linkSinceStates,
);

/// Every session the host holds, live.
final companionSessionsProvider = StreamProvider<List<CompanionSessionSummary>>(
  (ref) => ref.watch(companionGatewayProvider).watchSessions(),
);

/// One session's transcript, live.
final companionTranscriptProvider = StreamProvider.autoDispose
    .family<List<CompanionChatMessage>, String>(
      (ref, sessionId) =>
          ref.watch(companionGatewayProvider).transcript(sessionId),
    );

/// One session's pending approval, or null.
final companionApprovalProvider = StreamProvider.autoDispose
    .family<CompanionApproval?, String>(
      (ref, sessionId) =>
          ref.watch(companionGatewayProvider).pendingApproval(sessionId),
    );

/// **What one session is doing right now**, live.
final companionActivityProvider = StreamProvider.autoDispose
    .family<CompanionActivity, String>(
      (ref, sessionId) =>
          ref.watch(companionGatewayProvider).activity(sessionId),
    );

/// One session's approvals going away, and why. Events-only, so a screen that
/// opens after the fact stays quiet rather than announcing old news.
final companionApprovalResolutionProvider = StreamProvider.autoDispose
    .family<CompanionApprovalResolution, String>(
      (ref, sessionId) => ref
          .watch(companionGatewayProvider)
          .approvalResolutions
          .where((resolution) => resolution.sessionId == sessionId),
    );

/// The phone's inbox: sessions currently claiming attention, newest first.
final companionInboxProvider = Provider<List<CompanionSessionSummary>>((ref) {
  final sessions =
      ref.watch(companionSessionsProvider).asData?.value ??
      const <CompanionSessionSummary>[];
  final waiting = [
    for (final session in sessions)
      if (session.attention != null) session,
  ]..sort((a, b) => b.attention!.at.compareTo(a.attention!.at));
  return waiting;
});

/// The badge the Inbox tab shows.
final companionInboxCountProvider = Provider<int>(
  (ref) => ref.watch(companionInboxProvider).length,
);

/// One session by id, or null once it disappears from the host's list.
final companionSessionProvider = Provider.autoDispose
    .family<CompanionSessionSummary?, String>((ref, sessionId) {
      final sessions = ref.watch(companionSessionsProvider).asData?.value;
      if (sessions == null) return null;
      for (final session in sessions) {
        if (session.id == sessionId) return session;
      }
      return null;
    });

/// What could be started on the active desktop: its projects, their checkouts
/// and the agents installed where each checkout lives.
///
/// A pull, not a subscription — projects and installations change when the
/// user changes them on the desktop, not while a phone watches — so the start
/// screen reads it once and `ref.invalidate` is the retry.
final companionActiveHostKeyProvider = Provider<String?>((ref) {
  // Watch both streams so link/host changes invalidate the pull, while using
  // the gateway's current values makes the first read deterministic too.
  ref.watch(companionLinkProvider);
  ref.watch(companionPairingProvider);
  final gateway = ref.watch(companionGatewayProvider);
  final pairing = gateway.pairing;
  if (gateway.link != CompanionLinkState.connected || pairing == null) {
    return null;
  }
  return pairing.hostId?.value ?? pairing.hostName;
});

final companionWorkspaceProvider = FutureProvider.autoDispose<
  List<RemoteWorkspaceProject>
>((ref) {
  if (ref.watch(companionActiveHostKeyProvider) == null) {
    return const <RemoteWorkspaceProject>[];
  }
  return ref.watch(companionGatewayProvider).listWorkspace();
});

/// Projects on the active desktop, including projects with no sessions.
/// This is deliberately a pull separate from the live session stream: a new
/// transcript/status event must not trigger another project scan. Link changes
/// invalidate the host snapshot; callers can invalidate it for an explicit
/// refresh after a mutation.
final companionProjectsProvider = FutureProvider.autoDispose<
  List<RemoteWorkspaceProject>
>((ref) {
  if (ref.watch(companionActiveHostKeyProvider) == null) {
    return const <RemoteWorkspaceProject>[];
  }
  return ref.watch(companionGatewayProvider).listProjects();
});
