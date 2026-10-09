part of 'workbench.dart';

class _WorkbenchSession {
  const _WorkbenchSession({
    required this.id,
    required this.title,
    required this.paneId,
    required this.native,
    this.chatOnly = false,
  });

  final String id;
  final String title;

  /// The pane this session can be *shown* in. Null for an imported CLI session,
  /// one opened in an external terminal, and one whose pane has been ended.
  final String? paneId;
  final bool native;

  /// The conversation is this session's only face: its agent is spoken to
  /// over ACP, so there is no terminal and nothing to toggle to.
  final bool chatOnly;
}

/// The terminal rendering of a session: the panes, and nothing over them. A
/// session with **no pane of ours** gets [_NoPaneForSession] in their place.
class _TerminalSurface extends StatelessWidget {
  const _TerminalSurface({
    this.session,
    this.groupId,
    this.groupFocused = true,
  });

  final _WorkbenchSession? session;

  /// The group whose tabs these panes belong to — see [_WorkspaceGroup].
  final String? groupId;
  final bool groupFocused;

  @override
  Widget build(BuildContext context) {
    final selected = session;
    if (selected != null && selected.paneId == null) {
      return _NoPaneForSession(session: selected, groupId: groupId);
    }
    return TerminalPaneStack(groupId: groupId, groupFocused: groupFocused);
  }
}

/// What the terminal surface shows for a session nothing of ours is running,
/// read off the same pair the conversation's empty hint reads.
class _NoPaneForSession extends ConsumerWidget {
  const _NoPaneForSession({required this.session, required this.groupId});

  final _WorkbenchSession session;

  /// The group this empty state is drawn in — so "read the conversation" opens
  /// it *here* rather than in whichever group has the keyboard.
  final String? groupId;

  /// Whether resuming is something we could actually do: a native row needs the
  /// CLI's own id, or a "resume" would start a *new* conversation.
  bool _canResume(WidgetRef ref) {
    if (!session.native) return true;
    final id = ref
        .read(sessionsDataProvider)
        .getById(session.id)
        ?.externalSessionId;
    return id != null && id.isNotEmpty;
  }

  Future<void> _resume(WidgetRef ref) async {
    final actions = ref.read(explorerActionsProvider);
    final result = session.native
        ? await actions.openNative(session.id)
        : await () async {
            final record = ref
                .read(importedSessionsProvider)
                .getById(session.id);
            return record == null
                ? const ExplorerResult(ExplorerOutcome.selected)
                : await actions.openImported(record);
          }();
    final message = result.message;
    if (message == null || !ref.context.mounted) return;
    ScaffoldMessenger.of(
      ref.context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Whether the session runs — here or at the server. Then its terminal is
  /// on its way, and a resume would start a second copy.
  bool _running(WidgetRef ref) {
    if (!session.native) return false;
    ref.watchSessionKinds(const {SessionChangeKind.status});
    final row = ref.read(sessionsDataProvider).getById(session.id);
    return row?.status == SessionStatus.running ||
        (ref.read(hostLifecycleSubscriberProvider)?.isRunning(session.id) ??
            false);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wait = session.native
        ? ref.watch(sessionSlotWaitProvider(session.id))
        : null;
    final running = wait == null && _running(ref);
    final canResume = wait == null && !running && _canResume(ref);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.terminal,
                size: Chrome.iconHero,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: Insets.md),
              Text(
                session.title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                wait != null
                    ? slotWaitText(wait)
                    : running
                    ? 'This session is running. Its terminal opens here once '
                          'it is connected; the conversation can be read now.'
                    : canResume
                    ? 'No terminal of ours is running this session. Resume it '
                          'to pick the conversation up in one.'
                    : 'No terminal of ours is running this session, and we '
                          'never learned the conversation\'s own id — so it '
                          'cannot be resumed from here. "Copy resume command" '
                          'in the session menu is the way back into it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Insets.md),
              if (wait != null)
                SlotWaitActions(waiter: wait)
              else
                Wrap(
                  spacing: Insets.sm,
                  alignment: WrapAlignment.center,
                  children: [
                    if (canResume)
                      FilledButton.tonalIcon(
                        onPressed: () => _resume(ref),
                        icon: const Icon(AppIcons.playCircle),
                        label: const Text('Resume in a terminal'),
                      ),
                    TextButton(
                      // This card is drawn inside one group, so the conversation
                      // opens in that group.
                      onPressed: () {
                        if (groupId case final group?) {
                          ref
                              .read(terminalSessionsControllerProvider.notifier)
                              .showFaceIn(group, terminal: false);
                        }
                      },
                      child: const Text('Read the conversation'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
