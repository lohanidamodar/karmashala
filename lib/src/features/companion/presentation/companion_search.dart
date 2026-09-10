/// Finding a project or a session in what the phone already holds: a filter
/// over the snapshot, never a query frame, so a screen names its age (§19).
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

/// The rows of [sessions] that match, in the host's order. [keepId] is never
/// filtered away, so the session a screen is open on stays on screen.
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

/// The groups that match, in the host's order. Naming a project brings all its
/// sessions; [keepKey] keeps the one a screen is open on even if it misses.
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

/// The field above a companion list. Not focused on open: a keyboard that
/// springs up covers half the list the user came to read.
class CompanionSearchField extends StatelessWidget {
  const CompanionSearchField({
    required this.controller,
    required this.query,
    required this.onChanged,
    this.hintText = 'Search projects and sessions',
    super.key,
  });

  final TextEditingController controller;

  /// The raw text, so the clear button appears only when there is something to
  /// clear.
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
