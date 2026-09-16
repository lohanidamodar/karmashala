import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import '../application/session_chat_source.dart';
import '../application/session_providers.dart';
import '../application/session_recap_service.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/resume.dart';

/// The sessions a recap is being written for right now. Not persisted: an app
/// that closed mid-recap spent the turn, and a restored spinner waits forever.
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

/// Asks [sessionId]'s own CLI for a recap. **The only door**, which is what
/// makes "never on a tick, never at launch, never at the end" checkable.
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

/// The recap at the top of a conversation, with the age of the reading. Draws
/// nothing until somebody asks — never a panel that invites a spend.
class SessionRecapCard extends ConsumerWidget {
  const SessionRecapCard({required this.sessionId, super.key});

  final String sessionId;

  /// Below this height a pinned header would leave the text no line to show.
  static const _pinnedHeaderFloor = 96.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recap = ref.watch(sessionRecapProvider(sessionId));
    if (recap == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final running = ref.watch(sessionRecapRunningProvider(sessionId));
    // Null while the transcript is still loading: a zero here would report
    // every recap as covering more than the session holds.
    final turnsNow = ref
        .watch(sessionChatTranscriptProvider(sessionId))
        .asData
        ?.value
        .length;
    final stale = turnsNow != null && recap.isStaleAgainst(turnsNow);

    final header = Row(
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
          const InlineSpinner()
        else if (stale)
          // Offered only where it would say something new: a turn
          // spent re-deriving the text already on screen is wasted.
          TextButton.icon(
            icon: const Icon(AppIcons.arrowsClockwise),
            label: const Text('Recap again'),
            onPressed: () => requestSessionRecap(context, ref, sessionId),
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
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(recap.text, style: theme.textTheme.bodySmall),
        const SizedBox(height: Insets.xs),
        Text(
          _provenance(recap, ref, stale: stale, turnsNow: turnsNow),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );

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
        // The text scrolls under a pinned header inside whatever height the
        // conversation spares it; a pane too short for that scrolls it all.
        child: LayoutBuilder(
          builder: (context, box) => box.maxHeight < _pinnedHeaderFloor
              ? SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.all(Insets.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [header, body],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(Insets.sm),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header,
                      Flexible(
                        child: SingleChildScrollView(
                          primary: false,
                          child: body,
                        ),
                      ),
                    ],
                  ),
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
