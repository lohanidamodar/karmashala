// **Presence at touch density** (Stage 2 step 9): "Typing: *client* — Take
// over" as a full-width banner a thumb can hit, a keystroke refused said in
// it, and the grid the pane draws at with *Fit to this phone* behind it.

part of 'terminal_presence.dart';

/// How long the banner says a keystroke from here was not sent.
const _refusalShown = Duration(seconds: 4);

class _TouchPresence extends StatefulWidget {
  const _TouchPresence({required this.instance, required this.child});

  final HostTerminalInstance instance;
  final Widget child;

  @override
  State<_TouchPresence> createState() => _TouchPresenceState();
}

class _TouchPresenceState extends State<_TouchPresence> {
  Timer? _clear;

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }

  bool _refusedLately(DateTime? at) {
    if (at == null) return false;
    final left = _refusalShown - DateTime.now().difference(at);
    if (left <= Duration.zero) return false;
    _clear?.cancel();
    _clear = Timer(left, () {
      if (mounted) setState(() {});
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final instance = widget.instance;
    // Always this Stack, so the pane under it is never remounted.
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<HostPresence?>(
            valueListenable: instance.presence,
            builder: (context, presence, _) => ValueListenableBuilder<bool>(
              valueListenable: instance.atSessionGrid,
              builder: (context, atSessionGrid, _) =>
                  ValueListenableBuilder<DateTime?>(
                    valueListenable: instance.keystrokeRefusedAt,
                    builder: (context, refusedAt, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (presence != null && presence.heldElsewhere)
                          _TouchTypingBanner(
                            holder: presence.holder!,
                            refused: _refusedLately(refusedAt),
                            onTakeOver: instance.takeOver,
                          ),
                        _GridChip(
                          instance: instance,
                          atSessionGrid: atSessionGrid,
                          columns:
                              presence?.columns ?? instance.terminal.viewWidth,
                          rows: presence?.rows ?? instance.terminal.viewHeight,
                        ),
                      ],
                    ),
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TouchTypingBanner extends StatelessWidget {
  const _TouchTypingBanner({
    required this.holder,
    required this.refused,
    required this.onTakeOver,
  });

  final String holder;

  /// A keystroke from here was refused: the holder typed within 3 s.
  final bool refused;
  final Future<void> Function() onTakeOver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: refused ? scheme.errorContainer : scheme.secondaryContainer,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.target),
        child: Padding(
          padding: const EdgeInsets.only(left: Insets.md, right: Insets.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  refused
                      ? 'Not sent — $holder typed in the last 3 s'
                      : 'Typing: $holder',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: refused
                        ? scheme.onErrorContainer
                        : scheme.onSecondaryContainer,
                  ),
                ),
              ),
              TextButton(
                key: const Key('terminal-take-over'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(Touch.target, Touch.target),
                ),
                onPressed: onTakeOver,
                child: const Text('Take over'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The grid the pane draws at, small in the corner; a tap explains it and
/// offers *Fit to this phone*, or the way back to the session's size.
class _GridChip extends StatelessWidget {
  const _GridChip({
    required this.instance,
    required this.atSessionGrid,
    required this.columns,
    required this.rows,
  });

  final HostTerminalInstance instance;
  final bool atSessionGrid;
  final int columns;
  final int rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = atSessionGrid ? '$columns×$rows' : 'Fitted';
    return Semantics(
      button: true,
      label: atSessionGrid
          ? 'Terminal drawn at the session size, $columns by $rows'
          : 'Terminal fitted to this phone',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_explain(context)),
        child: SizedBox(
          height: Touch.target,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
            child: Center(
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.9,
                  ),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm,
                    vertical: Insets.xs,
                  ),
                  child: Text(label, style: theme.textTheme.labelSmall),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _explain(BuildContext context) => showAdaptiveModal<void>(
    context: context,
    title: 'Terminal size',
    builder: (sheet) {
      final theme = Theme.of(sheet);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              atSessionGrid
                  ? 'Drawn at the session’s own size, $columns×$rows, so '
                        'nobody else’s view changes. Pinch to zoom; tap twice '
                        'with two fingers to fit the width.'
                  : 'Fitted to this phone. The session stays at this size '
                        'until whoever types in it next resizes it.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Insets.md),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(Touch.target),
              ),
              onPressed: () {
                Navigator.of(sheet).pop();
                if (atSessionGrid) {
                  unawaited(instance.fitToView());
                } else {
                  instance.drawAtSessionGrid();
                }
              },
              child: Text(
                atSessionGrid
                    ? 'Fit to this phone'
                    : 'Back to the session’s size',
              ),
            ),
            if (atSessionGrid) ...[
              const SizedBox(height: Insets.xs),
              Text(
                'Resizes the session for everyone watching it, and takes '
                'its input.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
