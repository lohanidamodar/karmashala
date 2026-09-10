/// What is running, on top, in every list the phone draws. The snapshot decides
/// membership, rows are lifted and not copied, and none means no group at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
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

/// The pinned group. Draws nothing when [sessions] is empty, so a caller that
/// has not checked cannot put an empty box on screen.
class RunningSessionsGroup extends ConsumerWidget {
  const RunningSessionsGroup({
    required this.sessions,
    this.showProject = false,
    super.key,
  });

  /// Exactly the rows the snapshot called working, in the host's order.
  final List<CompanionSessionSummary> sessions;

  /// Names each row's project on the card's whereabouts line — true where this
  /// group crosses projects.
  final bool showProject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (sessions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.read(companionClockProvider).nowUtc();
    // The age of the snapshot membership came from, not of this frame
    // (CLAUDE.md §19).
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
              // Expanded, not a Spacer: at 200% text the count is the half of
              // the row that may ellipsise.
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
