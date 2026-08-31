import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/domain/session_resume.dart';
import '../application/companion_providers.dart';
import '../client/companion_gateway.dart';
import 'companion_route.dart';
import 'companion_states.dart';
import 'session_view_screen.dart';

/// The attention inbox on the phone: sessions the host says are waiting,
/// newest first, each one tap from its transcript.
///
/// This is the tab that answers "what needs me" **across** projects, which is
/// why the Projects tab does not have to: one screen per question.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(companionSessionsProvider);
    final waiting = ref.watch(companionInboxProvider);
    final now = ref.read(clockProvider).nowUtc();
    final scheme = Theme.of(context).colorScheme;

    return companionAsync(
      sessions,
      loading: () => const CompanionSkeletonList(lines: 2),
      error: (error) => CompanionNotice.failure(
        error: error,
        onRetry: () {
          ref.read(companionGatewayProvider).reconnect();
          ref.invalidate(companionSessionsProvider);
        },
      ),
      data: (_) => waiting.isEmpty
          ? const CompanionNotice(
              icon: AppIcons.checkCircle,
              tone: NoticeTone.idle,
              title: 'Nothing needs you.',
              body:
                  'Sessions that finish, fail, or stop to ask you something '
                  'collect here.',
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: Insets.xl),
              itemCount: waiting.length,
              separatorBuilder: (context, index) => Divider(
                height: 1,
                thickness: 1,
                indent: Insets.lg,
                color: scheme.outlineVariant,
              ),
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
    final density = UiDensity.of(context);
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
        companionRoute<void>(
          context,
          (_) => SessionViewScreen(sessionId: session.id),
        ),
      ),
      child: Container(
        constraints: density.isTouch
            ? const BoxConstraints(minHeight: Touch.target)
            : null,
        padding: EdgeInsets.symmetric(
          horizontal: density.padX,
          vertical: density.padY,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: density.icon, color: colour),
            ),
            SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    maxLines: density.isTouch ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: density.title(theme),
                  ),
                  SizedBox(height: density.lineGap),
                  Text(
                    '${attention.kind.label}  ·  '
                    '${session.projectName}  ·  '
                    '${describeAge(now.difference(attention.at))}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: density.muted(theme),
                  ),
                ],
              ),
            ),
            SizedBox(width: density.glyphGap),
            Icon(
              AppIcons.caretRight,
              size: density.icon,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
