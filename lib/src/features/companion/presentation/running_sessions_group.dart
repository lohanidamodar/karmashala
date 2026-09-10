/// **What is running, on top, in every list the phone draws.**
///
/// On a desktop with 31 projects the session you came to check is two taps and
/// a scroll away, and it is the one row whose state is changing while you look
/// for it. So the rows the host says are working are drawn first, under a
/// header that says how many there are and how old the reading is.
///
/// Three rules it is built to, and each is a refusal:
///
/// * **The snapshot decides membership, not the phone.** A session that stops
///   leaves this group when the next snapshot says so — there is no local
///   timer taking it out early, and no optimistic guess putting it in.
/// * **A session appears once on a screen.** Where the list below is sessions
///   the running ones are *lifted* into the group rather than copied above it
///   ([partitionByRunning]); where the list below is projects there is nothing
///   to duplicate. This is a partition by status, the same operation
///   `groupByProject` performs by project — never a sort, which is the bug the
///   owner reported twice.
/// * **Nothing running means no group**, not an empty box with a zero in it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../application/companion_providers.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_session_list.dart';
import 'companion_states.dart';

/// [sessions] split into the ones the host says are working and the rest, each
/// in the host's own order.
({List<CompanionSessionSummary> running, List<CompanionSessionSummary> rest})
partitionByRunning(List<CompanionSessionSummary> sessions) => (
  running: [
    for (final session in sessions)
      if (session.status == CompanionSessionStatus.working) session,
  ],
  rest: [
    for (final session in sessions)
      if (session.status != CompanionSessionStatus.working) session,
  ],
);

/// The pinned group. Draws nothing at all when [sessions] is empty, so a caller
/// that has not checked still cannot put an empty box on screen.
class RunningSessionsGroup extends ConsumerWidget {
  const RunningSessionsGroup({
    required this.sessions,
    this.showProject = false,
    super.key,
  });

  /// Exactly the rows the snapshot called working, in the host's order.
  final List<CompanionSessionSummary> sessions;

  /// Names each row's project on the line the card keeps for whereabouts.
  /// True where this group crosses projects — on the projects index a pinned
  /// row is the only thing on screen that does not sit under a project's name.
  final bool showProject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (sessions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.read(clockProvider).nowUtc();
    // The age of the reading this group *is*, not of this frame: membership
    // came from the snapshot, so the snapshot's age is the honest caveat on
    // every count here (CLAUDE.md §19).
    final age = companionSnapshotAge(
      ref.watch(companionSessionsReceivedAtProvider),
      now,
    );
    final count = sessions.length == 1
        ? '1 session'
        : '${sessions.length} sessions';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.md,
            Insets.lg,
            Insets.sm,
          ),
          child: Row(
            children: [
              const CompanionSectionHeader('RUNNING NOW', gap: 0),
              const SizedBox(width: Insets.sm),
              // Expanded rather than a Spacer: at 200% text the count and the
              // heading have to share the row, and the count is the half that
              // may ellipsise.
              Expanded(
                child: Text(
                  '$count  ·  $age',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UiDensity.of(context).muted(theme),
                ),
              ),
            ],
          ),
        ),
        for (var index = 0; index < sessions.length; index++) ...[
          if (index > 0)
            Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant,
              indent: Insets.lg,
            ),
          CompanionSessionRow(
            session: sessions[index],
            now: now,
            showProject: showProject,
          ),
        ],
      ],
    );
  }
}
