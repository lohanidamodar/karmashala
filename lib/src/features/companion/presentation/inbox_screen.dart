import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/domain/session_resume.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'session_view_screen.dart';

/// The attention inbox on the phone: sessions the host says are waiting,
/// newest first, each one tap from its transcript.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sessions = ref.watch(companionSessionsProvider);
    final waiting = ref.watch(companionInboxProvider);
    final now = ref.read(clockProvider).nowUtc();

    return sessions.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Trouble(message: '$e'),
      data: (_) => waiting.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Insets.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.checkCircle,
                      size: 22,
                      color: SemanticColors.of(context).idle,
                    ),
                    const SizedBox(height: Insets.sm),
                    Text(
                      'Nothing needs you.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              itemCount: waiting.length,
              itemBuilder: (context, index) =>
                  _InboxRow(session: waiting[index], now: now),
            ),
    );
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({required this.session, required this.now});

  final CompanionSessionSummary session;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final attention = session.attention!;
    // The same glyph-and-colour pairs as the desktop inbox rows.
    final (icon, colour) = switch (attention.kind) {
      CompanionAttentionKind.needsYou => (
        AppIcons.question,
        semantic.attention,
      ),
      CompanionAttentionKind.failed => (
        AppIcons.warningCircle,
        semantic.failure,
      ),
      CompanionAttentionKind.finished => (AppIcons.checkCircle, semantic.idle),
    };

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionViewScreen(sessionId: session.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.md,
          Insets.sm,
          Insets.md,
          Insets.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: Chrome.icon, color: colour),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${attention.kind.label}  ·  '
                    '${session.projectName}  ·  '
                    '${describeAge(now.difference(attention.at))}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              AppIcons.caretRight,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _Trouble extends StatelessWidget {
  const _Trouble({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
