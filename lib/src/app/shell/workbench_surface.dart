part of 'workbench.dart';

// The terminal rendering of a session, and what stands in for it when nothing
// of ours is running that session.

class _WorkbenchSession {
  const _WorkbenchSession({
    required this.id,
    required this.title,
    required this.paneId,
    required this.native,
  });

  final String id;
  final String title;

  /// The pane this session can be *shown* in — it runs in one of ours and that
  /// pane is still there. Null for an imported CLI session, one opened in an
  /// external terminal, and one whose pane has been ended: those have a
  /// conversation to read but no terminal of ours to switch to.
  final String? paneId;
  final bool native;
}

/// The terminal rendering of a session: the panes, and nothing over them.
///
/// No approval card. The agent draws its own prompt here and it is answered by
/// typing into it, so a card repeating the question under the pane duplicated a
/// control the terminal already has; the approval card belongs to the
/// conversation, which has no other way to see that prompt. Everything else
/// that belongs to the session is one row further down, in [_SessionBar].
///
/// With a session selected that has **no pane of ours**, the panes are not what
/// this surface should show — the tab on screen would be some other session's.
/// [_NoPaneForSession] takes their place and says so.
class _TerminalSurface extends StatelessWidget {
  const _TerminalSurface({
    this.session,
    this.groupId,
    this.groupFocused = true,
    this.autoOpenDone = true,
  });

  final _WorkbenchSession? session;

  /// The group whose tabs these panes belong to — see [_WorkspaceGroup].
  final String? groupId;
  final bool groupFocused;
  final bool autoOpenDone;

  @override
  Widget build(BuildContext context) {
    final selected = session;
    if (selected != null && selected.paneId == null) {
      return _NoPaneForSession(session: selected, groupId: groupId);
    }
    return TerminalPaneStack(
      groupId: groupId,
      groupFocused: groupFocused,
      autoOpenDone: autoOpenDone,
    );
  }
}

/// What the terminal surface shows for a session nothing of ours is running.
///
/// This is what lets "a tap always lands on the terminal" be honest rather than
/// a lie told by showing an unrelated tab. Every sentence is read off
/// `sessionTerminalPane` and the row itself, which is the same pair the
/// conversation's empty hint reads, so the two surfaces cannot describe one
/// session differently.
///
/// It answers a session the user has **asked to see**. It is deliberately not
/// what ending a session leaves behind: that selection is released before this
/// is ever reached ([_releaseEndedPane]), because explaining the corpse of the
/// thing someone just finished with is not an answer to anything.
class _NoPaneForSession extends ConsumerWidget {
  const _NoPaneForSession({required this.session, required this.groupId});

  final _WorkbenchSession session;

  /// The group this empty state is drawn in — so "read the conversation" opens
  /// it *here* rather than in whichever group has the keyboard.
  final String? groupId;

  /// Whether resuming is something we could actually do. A native row needs the
  /// CLI's own id — without it a "resume" would start a *new* conversation
  /// wearing this row's title, which is the one thing the Explorer refuses to
  /// do (see `ExplorerActions.openNative`). An imported row is nothing but that
  /// id, so it always can.
  bool _canResume(WidgetRef ref) {
    if (!session.native) return true;
    final id = ref
        .read(sessionDaoProvider)
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
                .read(importedSessionDaoProvider)
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canResume = _canResume(ref);
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
                canResume
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
