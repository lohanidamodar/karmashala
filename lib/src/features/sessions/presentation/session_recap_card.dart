import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import '../application/session_chat_source.dart';
import '../application/session_providers.dart';
import '../application/session_recap_service.dart';
import '../domain/session_recap.dart';
import '../domain/session_resume.dart';

/// The sessions a recap is being written for right now.
///
/// A set rather than a flag, because two conversations can be open and the
/// Explorer can ask for a third. Nothing here is persisted: an app that closed
/// mid-recap has spent the turn either way, and a spinner restored from disk
/// would be waiting for a process that is gone.
class SessionRecapRuns extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void start(String sessionId) => state = {...state, sessionId};
  void finish(String sessionId) => state = {...state}..remove(sessionId);
}

final sessionRecapRunsProvider =
    NotifierProvider<SessionRecapRuns, Set<String>>(SessionRecapRuns.new);

/// Whether [sessionId] is waiting on a recap. Its own provider so one running
/// session does not rebuild every other session's row.
final sessionRecapRunningProvider = Provider.family<bool, String>(
  (ref, sessionId) =>
      ref.watch(sessionRecapRunsProvider.select((all) => all.contains(sessionId))),
);

/// Asks [sessionId]'s own CLI for a recap and reports what happened.
///
/// **The only door.** Every surface that offers a recap calls this, and nothing
/// else calls [SessionRecapService.write] — which is what makes "never on a
/// tick, never at launch, never when a session ends" checkable rather than
/// merely intended.
///
/// A second press while one is in flight is ignored rather than queued: the
/// first is already spending the turn this one would spend again.
Future<void> requestSessionRecap(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final runs = ref.read(sessionRecapRunsProvider.notifier);
  if (ref.read(sessionRecapRunningProvider(sessionId))) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  runs.start(sessionId);
  try {
    await ref.read(sessionRecapServiceProvider).write(sessionId);
  } on SessionRecapRefusal catch (refusal) {
    messenger?.showSnackBar(SnackBar(content: Text(refusal.reason)));
  } finally {
    runs.finish(sessionId);
  }
}

/// The recap at the top of a conversation, with the age of the reading.
///
/// Above the messages and outside the scroll, because the whole point of it is
/// that it is there when the session opens — a digest that has to be scrolled
/// back to is a digest of a conversation you have already re-read. It draws
/// nothing at all until somebody asks for one (§19: never a panel that invites
/// a spend by looking empty).
class SessionRecapCard extends ConsumerWidget {
  const SessionRecapCard({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recap = ref.watch(sessionRecapProvider(sessionId));
    if (recap == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final running = ref.watch(sessionRecapRunningProvider(sessionId));
    // Null while the transcript is still loading. An unknown is never a zero,
    // and a zero here would report every recap as covering more than the
    // session holds — which is not a state that exists.
    final turnsNow = ref
        .watch(sessionChatTranscriptProvider(sessionId))
        .asData
        ?.value
        .length;
    final stale = turnsNow != null && recap.isStaleAgainst(turnsNow);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.sm,
        Insets.md,
        Insets.xs,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 2),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    AppIcons.article,
                    size: Chrome.iconSmall,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: Insets.sm),
                  Text('Recap', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  if (running)
                    const SizedBox(
                      width: Chrome.iconSmall,
                      height: Chrome.iconSmall,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (stale)
                    // Offered only where it would say something new. A recap of
                    // a conversation that has not moved would cost a turn to
                    // re-derive the text already on screen.
                    TextButton.icon(
                      icon: const Icon(AppIcons.arrowsClockwise),
                      label: const Text('Recap again'),
                      onPressed: () =>
                          requestSessionRecap(context, ref, sessionId),
                    ),
                  IconButton(
                    tooltip: 'Dismiss this recap',
                    icon: const Icon(AppIcons.x),
                    iconSize: Chrome.iconSmall,
                    onPressed: () {
                      ref.read(sessionRecapDaoProvider).delete(sessionId);
                      ref.invalidate(sessionRecapProvider(sessionId));
                    },
                  ),
                ],
              ),
              SelectableText(recap.text, style: theme.textTheme.bodySmall),
              const SizedBox(height: Insets.xs),
              Text(
                _provenance(recap, ref, stale: stale, turnsNow: turnsNow),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Who wrote it, when, and over how much — the three facts that decide how
  /// much to trust the paragraphs above (§19's second rule).
  String _provenance(
    SessionRecap recap,
    WidgetRef ref, {
    required bool stale,
    required int? turnsNow,
  }) {
    final now = ref.read(clockProvider).nowUtc();
    final agent = AgentRegistry.builtIn.displayNameFor(recap.agentId);
    final model = recap.model == null ? '' : ' (${recap.model})';
    final age = describeAge(now.difference(recap.writtenAt));
    final over = '${recap.turnCount} turn${recap.turnCount == 1 ? '' : 's'}';
    final moved = stale && turnsNow != null
        ? ' · the session has moved since — ${turnsNow - recap.turnCount} more '
              'turn${turnsNow - recap.turnCount == 1 ? '' : 's'}'
        : '';
    return 'Written by $agent$model $age, over $over$moved';
  }
}
