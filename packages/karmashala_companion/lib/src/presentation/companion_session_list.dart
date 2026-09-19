/// The host's session rows, drawn with the Explorer's own [SessionCard] at
/// touch density — the desktop's widget, not a phone lookalike.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_status_badge.dart';
import 'session_view_screen.dart';

/// One project's sessions, in the host's order, one tap from their transcripts.
class CompanionSessionList extends ConsumerWidget {
  const CompanionSessionList({
    required this.sessions,
    this.header,
    this.bottomInset = Insets.xl,
    super.key,
  });

  /// Exactly as the host ordered them. Never sorted here.
  final List<CompanionSessionSummary> sessions;

  /// The project this list belongs to, drawn above the first row when the
  /// screen has not already named it in its app bar.
  final Widget? header;

  /// Room under the last row — [companionFabGutter] where a floating action
  /// button hovers over the list.
  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.read(companionClockProvider).nowUtc();
    final offset = header == null ? 0 : 1;
    return ListView.separated(
      padding: companionListInsets(
        context,
        EdgeInsets.only(bottom: bottomInset),
      ),
      itemCount: sessions.length + offset,
      separatorBuilder: (context, index) =>
          CompanionRowDivider(indent: index < offset ? 0 : Insets.lg),
      itemBuilder: (context, index) {
        if (index < offset) return header!;
        return CompanionSessionRow(session: sessions[index - offset], now: now);
      },
    );
  }
}

/// When the host last heard from [session], or null when it sent no time. One
/// function, so the dedicated last-active field the host is gaining moves one
/// line.
DateTime? companionLastActiveAt(CompanionSessionSummary session) =>
    session.lastActivityAt;

/// That reading in the words the rest of the app uses — "active 3m ago" — or
/// null when there is no reading, because unknown is not zero (CLAUDE.md §19).
String? companionLastActiveLabel(
  CompanionSessionSummary session,
  DateTime now,
) {
  final at = companionLastActiveAt(session);
  return at == null ? null : 'active ${describeAge(now.difference(at))}';
}

/// One session as the Explorer draws it, fed by the gateway.
class CompanionSessionRow extends StatelessWidget {
  const CompanionSessionRow({
    required this.session,
    required this.now,
    this.showProject = false,
    super.key,
  });

  final CompanionSessionSummary session;
  final DateTime now;

  /// Names the row's project on the whereabouts line. Off inside a project's
  /// own list, where every row would repeat the app bar.
  final bool showProject;

  @override
  Widget build(BuildContext context) {
    // Appended rather than replacing: an archived or folder-less session is
    // still listed, and says why.
    final notes = [
      if (showProject && session.projectName.isNotEmpty) session.projectName,
      if (session.folderMissing) 'folder missing',
      if (session.archived) 'archived',
      ?session.whereabouts,
    ];
    return SessionCard(
      depth: 0,
      selected: false,
      agentIcon: AppIcons.robot,
      agentLabel: switch (session.model) {
        final model? => '${session.agentLabel}  ·  $model',
        null => session.agentLabel,
      },
      // The word beside the glyph, always: amber and green are not a
      // distinction everyone can see.
      badge: CompanionStatusBadge(status: session.status, showLabel: true),
      age: companionLastActiveLabel(session, now),
      title: session.title,
      branch: session.branch,
      subPath: session.subPath,
      whereabouts: notes.isEmpty ? null : notes.join('  ·  '),
      worktree: session.worktree,
      // A phone can open a session and nothing else, so there is no menu.
      showMenu: false,
      onTap: () => Navigator.of(context).push(
        companionRoute<void>(
          context,
          (_) => SessionViewScreen(sessionId: session.id),
        ),
      ),
      menuItemsBuilder: () => const [],
      onMenu: (_) {},
    );
  }
}
