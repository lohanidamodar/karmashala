/// Finding a project or a session **in what the phone already holds**.
///
/// Nothing here asks the desktop anything. A desktop with 31 projects and 39
/// watched sessions is a scroll on a phone, and the answer is a filter over
/// the snapshot in hand — not a query frame, not a poll (CLAUDE.md §19). The
/// consequence is that a result is only ever as good as the snapshot behind
/// it, so every screen that filters also says how old that snapshot is, and
/// the empty state says it loudest.
///
/// The rule is the Explorer's, deliberately: one case-folded substring, over
/// the project's **name and path** and the session's **title and agent**.
/// Those are the four things a user knows a row by; matching more (a branch, a
/// whereabouts clause) makes a query mean something different on the phone
/// than it does on the desktop.
library;

import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';
import 'project_group.dart';

/// What the widgets hold turned into what the matchers take: trimmed, folded,
/// and empty for "no filter at all".
String companionSearchQuery(String raw) => raw.trim().toLowerCase();

/// The session's title and the agent label the host wrote for it.
bool companionSessionMatches(CompanionSessionSummary session, String query) =>
    query.isEmpty ||
    session.title.toLowerCase().contains(query) ||
    session.agentLabel.toLowerCase().contains(query);

/// The project's name and its folder on the host.
bool companionProjectMatches(CompanionProjectGroup group, String query) =>
    query.isEmpty ||
    group.name.toLowerCase().contains(query) ||
    group.path.toLowerCase().contains(query);

/// The rows of [sessions] that match, in the host's order.
///
/// [keepId] is never filtered away: the session a screen is open on stays on
/// screen as the filter narrows, the way the desktop's scope filter keeps the
/// selected project (`workspaceScopedProjectsProvider`).
List<CompanionSessionSummary> companionMatchingSessions(
  List<CompanionSessionSummary> sessions,
  String query, {
  String? keepId,
}) {
  if (query.isEmpty) return sessions;
  return [
    for (final session in sessions)
      if (session.id == keepId || companionSessionMatches(session, query))
        session,
  ];
}

/// The groups of [groups] that match, in the host's order, each carrying only
/// the sessions that match.
///
/// **Naming a project brings all of its sessions.** Someone who typed a
/// project's name is asking for that project, not for the sessions whose
/// titles happen to repeat it; narrowing inside a named project would hide
/// rows for a word the user never applied to them.
///
/// [keepKey] is the counterpart of [companionMatchingSessions]'s `keepId`: the
/// project a screen is open on survives a filter that excludes it, with its
/// own sessions still narrowed. A screen that dropped it would say "this
/// project is gone" about a project that is merely not a match.
List<CompanionProjectGroup> companionMatchingGroups(
  List<CompanionProjectGroup> groups,
  String query, {
  String? keepKey,
}) {
  if (query.isEmpty) return groups;
  final kept = <CompanionProjectGroup>[];
  for (final group in groups) {
    final named = companionProjectMatches(group, query);
    final sessions = named
        ? group.sessions
        : companionMatchingSessions(group.sessions, query);
    if (!named && sessions.isEmpty && group.key != keepKey) continue;
    kept.add(
      identical(sessions, group.sessions)
          ? group
          : group.withSessions(sessions),
    );
  }
  return kept;
}

/// The field above a companion list.
///
/// **Not focused on open.** A phone keyboard that springs up on every visit
/// covers half the list the user came to read, and costs more than the one tap
/// it saves.
class CompanionSearchField extends StatelessWidget {
  const CompanionSearchField({
    required this.controller,
    required this.query,
    required this.onChanged,
    this.hintText = 'Search projects and sessions',
    super.key,
  });

  final TextEditingController controller;

  /// The raw text, so the clear button appears exactly when there is something
  /// to clear.
  final String query;

  final ValueChanged<String> onChanged;
  final String hintText;

  void _clear() {
    controller.clear();
    onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    return CompanionReadable(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.lg,
          Insets.sm,
          Insets.lg,
          Insets.sm,
        ),
        child: TextField(
          controller: controller,
          autofocus: false,
          textInputAction: TextInputAction.search,
          onChanged: onChanged,
          decoration: InputDecoration(
            isDense: true,
            hintText: hintText,
            border: const OutlineInputBorder(),
            prefixIcon: Icon(
              AppIcons.magnifyingGlass,
              size: density.isTouch ? Touch.icon : Chrome.icon,
            ),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(AppIcons.x),
                    onPressed: _clear,
                  ),
          ),
        ),
      ),
    );
  }
}
