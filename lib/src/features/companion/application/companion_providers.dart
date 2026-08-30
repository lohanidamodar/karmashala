/// Riverpod bridges from the [CompanionGateway] streams to the phone UI.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../client/companion_gateway.dart';

/// The pairing in effect, or null when this phone has never paired.
final companionPairingProvider = StreamProvider<CompanionPairing?>(
  (ref) => ref.watch(companionGatewayProvider).pairingStates,
);

/// Whether the phone can currently reach the host.
final companionLinkProvider = StreamProvider<CompanionLinkState>(
  (ref) => ref.watch(companionGatewayProvider).linkStates,
);

/// Which path carries the link — Direct (LAN) or Relay — or null while down.
final companionLinkPathProvider = StreamProvider<CompanionLinkPath?>(
  (ref) => ref.watch(companionGatewayProvider).linkPathStates,
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
