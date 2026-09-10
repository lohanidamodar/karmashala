/// Riverpod bridges from the [CompanionGateway] streams to the phone UI.
library;

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_runtime.dart';

/// A list of sessions as the phone received it, with the instant it arrived —
/// one fact, since rows with no reading time cannot be shown honestly.
class CompanionSessionsSnapshot {
  const CompanionSessionsSnapshot({
    required this.sessions,
    required this.receivedAt,
  });

  final List<CompanionSessionSummary> sessions;

  /// When this phone received [sessions] — never when the host observed them.
  final DateTime receivedAt;
}

/// The gateway the companion UI reads. Defaults to an unpaired
/// [FakeCompanionGateway] so companion mode boots to the pairing screen; the
/// orchestrator overrides it with the real client.
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

/// Why the link is not up, when the gateway knows anything more exact than
/// "connecting". Its own stream because the reason arrives with no link-state
/// change under it, so a getter re-read on rebuild would never see it.
final companionLinkTroubleProvider = StreamProvider<String?>(
  (ref) => ref.watch(companionGatewayProvider).linkTroubleStates,
);

/// Every desktop this phone has paired with, one of them active.
final companionConnectionsProvider =
    StreamProvider<List<CompanionConnection>>(
      (ref) => ref.watch(companionGatewayProvider).connectionsStates,
    );

/// Drives [CompanionGateway.switchTo] / [CompanionGateway.removeConnection],
/// holding the in-flight host id so every surface shows the same progress.
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
      // Nothing may escape: the surfaces show `lastError` and nothing else, so
      // a refusal that gets past here is a tap that visibly did nothing.
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

/// The host's rows, stamped on arrival so their real age shows (§19). One
/// subscription: `watchSessions` is a `Stream.multi`, so a second is a frame.
final companionSessionsSnapshotProvider =
    StreamProvider<CompanionSessionsSnapshot>((ref) {
      final clock = ref.watch(companionClockProvider);
      return ref
          .watch(companionGatewayProvider)
          .watchSessions()
          .map(
            (rows) => CompanionSessionsSnapshot(
              sessions: rows,
              receivedAt: clock.nowUtc(),
            ),
          );
    });

/// Every session the host holds, live. Not `whenData`: a provider being retried
/// is `AsyncLoading` *carrying* its error, which `whenData` silently drops.
final companionSessionsProvider =
    Provider<AsyncValue<List<CompanionSessionSummary>>>((ref) {
      final snapshot = ref.watch(companionSessionsSnapshotProvider);
      // Rows if there are rows, then the reason there are none, then "not yet".
      if (snapshot.hasValue) return AsyncData(snapshot.requireValue.sessions);
      final failure = snapshot.error;
      if (failure != null) {
        return AsyncError(failure, snapshot.stackTrace ?? StackTrace.empty);
      }
      return const AsyncLoading();
    });

/// When this phone received the rows it is showing, or null while it has
/// received none. An unknown reading time is not a reading time (§19), so this
/// is null rather than "now" before the first snapshot lands.
final companionSessionsReceivedAtProvider = Provider<DateTime?>((ref) {
  final snapshot = ref.watch(companionSessionsSnapshotProvider);
  return snapshot.hasValue ? snapshot.requireValue.receivedAt : null;
});

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

/// What could be started on the active desktop. A pull, not a subscription:
/// projects change when the user changes them, so `ref.invalidate` is the retry.
final companionActiveHostKeyProvider = Provider<String?>((ref) {
  // Watch both streams so link/host changes invalidate the pull; the gateway's
  // current values make the first read deterministic.
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

/// Projects on the active desktop, including those with no sessions. A pull
/// separate from the session stream, so a transcript event cannot trigger
/// another project scan.
final companionProjectsProvider = FutureProvider.autoDispose<
  List<RemoteWorkspaceProject>
>((ref) {
  if (ref.watch(companionActiveHostKeyProvider) == null) {
    return const <RemoteWorkspaceProject>[];
  }
  return ref.watch(companionGatewayProvider).listProjects();
});
