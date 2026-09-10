/// The host's session rows, drawn with the Explorer's own card.
///
/// Not a phone lookalike: this is literally [SessionCard], the widget the
/// desktop pane uses, at touch density. One design language means a session
/// that reads a certain way on the desktop reads the same way in your hand.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/presentation/session_card.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
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

  /// Drawn above the first row and scrolling with it — the project this list
  /// belongs to, when the screen has not already named it in its app bar.
  final Widget? header;

  /// Room under the last row. [companionFabGutter] where a floating action
  /// button hovers over the list, so the last session is not half-covered by
  /// the button offering to start another one.
  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.read(clockProvider).nowUtc();
    final scheme = Theme.of(context).colorScheme;
    final offset = header == null ? 0 : 1;
    return ListView.separated(
      padding: companionListInsets(
        context,
        EdgeInsets.only(bottom: bottomInset),
      ),
      itemCount: sessions.length + offset,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        thickness: 1,
        color: scheme.outlineVariant,
        indent: index < offset ? 0 : Insets.lg,
      ),
      itemBuilder: (context, index) {
        if (index < offset) return header!;
        return CompanionSessionRow(session: sessions[index - offset], now: now);
      },
    );
  }
}

/// **When the host last heard from [session]**, or null when it sent no time.
///
/// One function on purpose. The reading currently comes from
/// `lastActivityAt`, the only instant a session row carries; the host is
/// gaining a dedicated last-active field, and this is the single line that has
/// to move when it lands.
DateTime? companionLastActiveAt(CompanionSessionSummary session) =>
    session.lastActivityAt;

/// That reading in the words the rest of the app uses — "active 3m ago" — or
/// null when there is no reading.
///
/// Null rather than "active just now": a session whose age the host never sent
/// has an unknown age, and unknown is not zero (CLAUDE.md §19). [describeAge]
/// rather than [compactAge] because a phone's card runs the full width of the
/// screen and has room for the word that says what the number means.
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
  /// own list, where every row would repeat the app bar; on where a list
  /// crosses projects and the name is the only thing placing the row.
  final bool showProject;

  @override
  Widget build(BuildContext context) {
    // The desktop's own clauses, appended to line three rather than replacing
    // it: an archived or folder-less session is still listed, and says why.
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
      agentLabel: session.agentLabel,
      // The word beside the glyph, always: a phone is the surface most likely
      // to be read in sunlight, at arm's length, by someone who does not see
      // amber and green as different colours.
      badge: CompanionStatusBadge(status: session.status, showLabel: true),
      age: companionLastActiveLabel(session, now),
      title: session.title,
      branch: session.branch,
      subPath: session.subPath,
      whereabouts: notes.isEmpty ? null : notes.join('  ·  '),
      worktree: session.worktree,
      // A phone can open a session and nothing else; an overflow menu with no
      // verbs in it is a target that does nothing.
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
