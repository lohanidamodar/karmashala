// Resume, and Allow / Deny on a phone's ask row.
part of '../attention_inbox_view.dart';

/// *Resume* on a turn an error ended: the session is still there, waiting at
/// its prompt, and "continue" picks the work up where it stopped.
class _ResumeAction extends ConsumerWidget {
  const _ResumeAction({required this.sessionId});

  final String sessionId;

  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    String? failure;
    try {
      final sent = await ref
          .read(sessionInputProvider)
          .send(sessionId, 'continue');
      if (!sent) failure = 'The session is not running here.';
    } on SessionPromptRefusal catch (refusal) {
      failure = refusal.message;
    }
    if (failure != null) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not resume: $failure')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton.icon(
      onPressed: () => unawaited(_resume(context, ref)),
      icon: const Icon(AppIcons.play, size: Chrome.iconAction),
      label: const Text('Resume'),
    ),
  );
}

/// *Allow* and *Deny* on a phone's ask row, for a plain approval only: a
/// question, or a menu this phone can read, is answered in the session, which
/// the row's tap opens. Each answer names the prompt it was drawn from, so a
/// late one is refused rather than landing on the next prompt.
class _InboxAnswers extends ConsumerStatefulWidget {
  const _InboxAnswers({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_InboxAnswers> createState() => _InboxAnswersState();
}

class _InboxAnswersState extends ConsumerState<_InboxAnswers> {
  bool _busy = false;

  Future<void> _answer(PromptAsk ask, {required bool approve}) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            ApprovalAnswerRequest(
              sessionId: widget.sessionId,
              approve: approve,
              ask: ask,
            ),
          );
      messenger.showSnackBar(
        SnackBar(content: Text(approve ? 'Allowed.' : 'Denied.')),
      );
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(
        SnackBar(content: Text(approvalRefusalText(refusal, touch: true))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final report =
        ref.watch(agentSessionStatusProvider(sessionId)).asData?.value ??
        ref.read(sessionStatusLookupProvider)(sessionId);
    if (report == null || !report.hasOpenPrompt) {
      return const SizedBox.shrink();
    }
    final rules = ref
        .read(agentRegistryProvider)
        .byId(report.agentId)
        ?.approval;
    if (rules?.approve == null || rules?.deny == null) {
      return const SizedBox.shrink();
    }
    if (!ref.read(sessionAnswerableProvider)(sessionId)) {
      return const SizedBox.shrink();
    }
    // A menu the session's page would draw as its own options, unless it is
    // the prompt a call raised: yes and no are then honestly its answers.
    if (report.toolAsk == null &&
        ref.read(sessionPromptAnswersProvider).menuOnScreen(sessionId) !=
            null) {
      return const SizedBox.shrink();
    }
    final ask = PromptAsk.drawnFrom(report);
    final scheme = Theme.of(context).colorScheme;
    final attention = SemanticColors.of(context).attention;
    // Ink on amber, as the dock's primary answer is drawn.
    final ink = Color.alphaBlend(
      Colors.black.withValues(alpha: 0.88),
      attention,
    );
    final idle = !_busy;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm, right: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              key: ValueKey('inbox-allow:$sessionId'),
              style: FilledButton.styleFrom(
                backgroundColor: attention,
                foregroundColor: ink,
                minimumSize: const Size.fromHeight(Touch.target),
              ),
              onPressed: idle ? () => _answer(ask, approve: true) : null,
              child: const Text('Allow'),
            ),
          ),
          const SizedBox(width: Touch.gap),
          Expanded(
            child: FilledButton(
              key: ValueKey('inbox-deny:$sessionId'),
              style: FilledButton.styleFrom(
                backgroundColor: SurfaceTones.of(context).selected,
                foregroundColor: scheme.onSurface,
                minimumSize: const Size.fromHeight(Touch.target),
              ),
              onPressed: idle ? () => _answer(ask, approve: false) : null,
              child: const Text('Deny'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Under a phone's ask that went without this phone, as the dock says it.
class _AnsweredElsewhereLine extends StatelessWidget {
  const _AnsweredElsewhereLine({required this.said});

  final String said;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        key: const ValueKey('inbox-answered-elsewhere'),
        padding: const EdgeInsets.only(top: Insets.sm, right: Insets.xs),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.target),
          child: Row(
            children: [
              Icon(
                AppIcons.checkCircle,
                size: Chrome.iconSmall,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  said,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
