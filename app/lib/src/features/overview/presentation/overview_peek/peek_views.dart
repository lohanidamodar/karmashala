// The peek's views: chat visibility, terminal, files and sub-sessions.
part of '../overview_peek.dart';

/// Counts the peek's chat as on screen while it is up: no workbench group
/// shows it, so the chat gate would otherwise never read a terminal
/// session's transcript.
class _ShownChat extends ConsumerStatefulWidget {
  const _ShownChat({required this.child});

  final Widget child;

  @override
  ConsumerState<_ShownChat> createState() => _ShownChatState();
}

class _ShownChatState extends ConsumerState<_ShownChat> {
  late final ChatsShownOutsideGroups _shown;
  var _counted = false;

  @override
  void initState() {
    super.initState();
    _shown = ref.read(chatsShownOutsideGroupsProvider.notifier);
    // After the frame: a provider is not changed while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shown.add();
      _counted = true;
    });
  }

  @override
  void dispose() {
    if (_counted) {
      final shown = _shown;
      Future.microtask(shown.remove);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The session's own terminal pane, live: what is typed here goes to it.
class _PeekTerminal extends ConsumerWidget {
  const _PeekTerminal({required this.paneId});

  final String paneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null) {
      return const PanePlaceholder(
        message: 'This session has no terminal open on this machine.',
        icon: AppIcons.terminal,
      );
    }
    final settings = ref.watch(settingsControllerProvider);
    return KeyedSubtree(
      key: ValueKey('overview-peek-terminal:$paneId'),
      child: LiveTerminalPane(
        paneId: paneId,
        fallback: instance,
        focused: true,
        fontSize: settings.terminalFontSize,
        terminalTheme: terminalThemeFor(
          Theme.of(context),
          ref.watch(terminalPaletteProvider),
        ),
        chordOverrides: settings.terminalChordOverrides,
        onKeyEvent: TerminalActions(ref).onPaneKey,
        onSecondaryTapDown: (_, _) {},
        // A click types here; it does not bring the session's tab forward.
        claimsPaneFocus: false,
        // Its own tab sizes the grid; the peek draws it at that size.
        sizesGrid: false,
      ),
    );
  }
}

/// The files the session changed, each with its +/− and, opened, its diff.
class _PeekFiles extends ConsumerStatefulWidget {
  const _PeekFiles({required this.card, required this.files});

  final OverviewCard card;
  final List<String>? files;

  @override
  ConsumerState<_PeekFiles> createState() => _PeekFilesState();
}

class _PeekFilesState extends ConsumerState<_PeekFiles> {
  String? _open;

  /// The height an opened diff is given inside the list.
  static const _diffHeight = Insets.xxl * 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final files = widget.files;
    if (files == null) {
      return Center(
        child: Text('What this session changed is not known.', style: muted),
      );
    }
    if (files.isEmpty) {
      return Center(
        child: Text('No files changed in this session yet.', style: muted),
      );
    }
    final checkout = widget.card.entry.directory;
    final stats = checkout == null
        ? const <String, FileDiffStat>{}
        : ref.watch(overviewFileStatsProvider(checkout)).value ??
              const <String, FileDiffStat>{};
    final semantic = SemanticColors.of(context);
    final sessionId = widget.card.entry.native?.id;
    final list = ListView(
      key: const ValueKey('overview-peek-files'),
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      children: [
        for (final path in files) ...[
          () {
            final relative = _relative(path, stats, checkout?.path);
            final stat = stats[relative];
            final name = path
                .split(RegExp(r'[\\/]'))
                .where((p) => p.isNotEmpty)
                .lastOrNull;
            return InkWell(
              key: ValueKey('overview-peek-file:$path'),
              onTap: checkout == null
                  ? null
                  : () => setState(() => _open = _open == path ? null : path),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.md,
                  vertical: Insets.xs,
                ),
                child: Row(
                  children: [
                    Icon(
                      _open == path ? AppIcons.caretDown : AppIcons.caretRight,
                      size: UiDensity.of(context).iconSmall,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Tooltip(
                        message: path,
                        child: Text(
                          name ?? path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                    if (stat != null && !stat.isBinary)
                      Text.rich(
                        TextSpan(
                          children: diffStatSpans(
                            semantic,
                            added: stat.added,
                            removed: stat.removed,
                          ),
                        ),
                        key: ValueKey('overview-peek-file-stat:$path'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
              ),
            );
          }(),
          if (_open == path && checkout != null) ...[
            if (sessionId != null)
              Builder(
                builder: (context) {
                  final review = HunkReviewScope.maybeOf(context);
                  if (review == null) return const SizedBox.shrink();
                  return Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: RevertFileButton(
                      path: _relative(path, stats, checkout.path),
                      hunks: const [],
                      review: review,
                    ),
                  );
                },
              ),
            SizedBox(
              height: _diffHeight,
              child: FileDiffView(
                key: ValueKey('overview-peek-diff:$path'),
                path: _relative(path, stats, checkout.path),
                checkout: checkout,
                repositoryId: widget.card.entry.native?.repositoryId,
                reviewHunks: sessionId != null,
              ),
            ),
          ],
        ],
      ],
    );
    if (sessionId == null || checkout == null) return list;
    // The working tree against git, a hunk at a time; Revert file is git's.
    return HunkReviewHost(
      sessionId: sessionId,
      gitCheckout: checkout,
      place: (relative) => checkoutFile(checkout, relative),
      openFile: (relative) => ref
          .read(editorTabActionsProvider)
          .openAt(checkoutFile(checkout, relative)),
      onReverted: () => ref.invalidate(diffForTargetProvider),
      child: list,
    );
  }

  /// [path] as the checkout's own git spells it: a key of [stats] it ends
  /// with, else [path] with the checkout's prefix taken off.
  static String _relative(
    String path,
    Map<String, FileDiffStat> stats,
    String? checkout,
  ) {
    final slashed = path.replaceAll(r'\', '/');
    for (final key in stats.keys) {
      if (slashed == key || slashed.endsWith('/$key')) return key;
    }
    final root = checkout?.replaceAll(r'\', '/');
    if (root != null && slashed.startsWith('$root/')) {
      return slashed.substring(root.length + 1);
    }
    return slashed;
  }
}

class _PeekSubSession extends ConsumerWidget {
  const _PeekSubSession({required this.card, this.onTap});

  final OverviewCard card;
  final ValueChanged<OverviewCard>? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final line = watchOverviewLine(ref, card);
    return Column(
      key: ValueKey('overview-peek-sub:${card.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewSubSessionRow(card: card, onOpen: (c) => onTap?.call(c)),
        Padding(
          padding: const EdgeInsets.only(
            left: Insets.lg + Insets.xs,
            bottom: Insets.xs,
          ),
          child: Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
