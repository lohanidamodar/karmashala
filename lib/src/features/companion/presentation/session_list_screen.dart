import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/presentation/session_card.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_status_badge.dart';
import 'session_view_screen.dart';

/// The host's sessions on the phone: the desktop's three-line cards (Loop
/// 50/58), single column, grouped under a project header.
class SessionListScreen extends ConsumerWidget {
  const SessionListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(companionSessionsProvider);
    final now = ref.read(clockProvider).nowUtc();
    final hostName = ref
        .watch(companionPairingProvider)
        .asData
        ?.value
        ?.hostName;

    return sessions.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _CentredNote(
        icon: AppIcons.warningCircle,
        message: '$e',
        error: true,
      ),
      data: (list) {
        if (list.isEmpty) {
          return _CentredNote(
            icon: AppIcons.chatCircle,
            message:
                'No sessions on ${hostName ?? 'your desktop'} yet.\n'
                'Start one there and it appears here.',
          );
        }
        // Group by the repository's real identity — two checkouts that share
        // a folder name are two projects — and keep the host's own ordering
        // both inside a group and across groups. The host's list IS the
        // order; re-sorting it here is what made the list jump.
        final byProject = <String, List<CompanionSessionSummary>>{};
        for (final session in list) {
          (byProject[session.projectKey] ??= []).add(session);
        }
        final children = <Widget>[];
        byProject.forEach((_, sessions) {
          children.add(
            _ProjectHeader(name: sessions.first.projectName, sessions: sessions),
          );
          for (final session in sessions) {
            children.add(_card(context, session, now));
          }
          children.add(const SizedBox(height: Insets.sm));
        });
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          children: children,
        );
      },
    );
  }

  Widget _card(
    BuildContext context,
    CompanionSessionSummary session,
    DateTime now,
  ) {
    final at = session.lastActivityAt;
    // The desktop's own clauses, appended to line three rather than replacing
    // it: an archived or folder-less session is still listed, and says why.
    final notes = [
      if (session.folderMissing) 'folder missing',
      if (session.archived) 'archived',
      if (session.whereabouts != null) session.whereabouts!,
    ];
    return SessionCard(
      depth: 0,
      selected: false,
      agentIcon: AppIcons.robot,
      agentLabel: session.agentLabel,
      badge: CompanionStatusBadge(status: session.status),
      age: at == null ? null : compactAge(now.difference(at)),
      title: session.title,
      branch: session.branch,
      subPath: session.subPath,
      whereabouts: notes.isEmpty ? null : notes.join('  ·  '),
      worktree: session.worktree,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionViewScreen(sessionId: session.id),
        ),
      ),
      menuItems: const [],
      onMenu: (_) {},
    );
  }
}

/// The project header a group of cards sits under — the desktop's shape
/// (name strong, facts muted, attention in its own colour), phone width.
class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.name, required this.sessions});

  final String name;
  final List<CompanionSessionSummary> sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: 0,
    );
    final waiting = sessions.where((s) => s.attention != null).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 2),
      child: Row(
        children: [
          Icon(
            AppIcons.folder,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text:
                      '${sessions.length} '
                      'session${sessions.length == 1 ? '' : 's'}',
                ),
                if (waiting > 0)
                  TextSpan(
                    text: '  ·  $waiting need${waiting == 1 ? 's' : ''} you',
                    style: TextStyle(
                      color: semantic.attention,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _CentredNote extends StatelessWidget {
  const _CentredNote({
    required this.icon,
    required this.message,
    this.error = false,
  });

  final IconData icon;
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 22,
              color: error ? scheme.error : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: error ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
