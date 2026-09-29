part of '../approval_request_card.dart';

/// A menu the agent drew, as one button per option in its own words: the
/// option that means yes filled amber, the rest on the raised tone. One
/// press answers — the button names the option, and the answer path moves
/// to it, checks it is highlighted, then confirms — so nothing is typed
/// that the user did not point at.
class _DockMenu extends StatefulWidget {
  const _DockMenu({
    required this.menu,
    required this.affirmative,
    required this.sessionId,
    required this.onChoose,
    this.affirmativeKey,
    this.negative,
    this.negativeKey,
  });

  final AgentScreenMenu menu;

  /// The option that means yes, drawn filled; null when none can be named.
  final int? affirmative;

  /// The key cap on [affirmative], when that key alone would pick it.
  final String? affirmativeKey;

  /// The option that means no, and the key cap on it when the agent's cancel
  /// is the same answer.
  final int? negative;
  final String? negativeKey;
  final String sessionId;
  final Future<void> Function(int option) onChoose;

  @override
  State<_DockMenu> createState() => _DockMenuState();
}

class _DockMenuState extends State<_DockMenu> {
  bool _busy = false;

  /// The widest an option's button grows before its words end; the tooltip
  /// keeps the whole of them.
  static const _optionMaxWidth = 320.0;

  Future<void> _choose(int option) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onChoose(option);
    } on GatewayException catch (refusal) {
      messenger.showSnackBar(SnackBar(content: Text(refusal.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.menu;
    return _DockColumn(
      children: [
        if (menu.prompt.isNotEmpty) _DockBox(text: menu.prompt.join('\n')),
        _DockButtonRow(
          sessionId: widget.sessionId,
          buttons: [
            for (var i = 0; i < menu.options.length; i++)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _optionMaxWidth),
                child: _DockButton(
                  key: ValueKey('dock-menu-option-$i'),
                  label: menu.options[i],
                  keyHint: i == widget.affirmative
                      ? widget.affirmativeKey
                      : i == widget.negative
                      ? widget.negativeKey
                      : null,
                  // An option in the agent's own words can run long; it
                  // wraps rather than ending mid-word (the tooltip keeps it).
                  wrap: true,
                  tooltip: i == menu.highlighted
                      ? '${menu.options[i]}\nHighlighted in the terminal — '
                            'what Enter alone would pick'
                      : menu.options[i],
                  primary: i == widget.affirmative,
                  onPressed: _busy ? null : () => _choose(i),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The notice for an ask the dock cannot answer, and the way to the one
/// place that can.
class _DockNote extends StatelessWidget {
  const _DockNote({required this.note, required this.sessionId});

  final String note;
  final String sessionId;

  @override
  Widget build(BuildContext context) => _DockButtonRow(
    sessionId: sessionId,
    buttons: [
      Text(note, style: UiDensity.of(context).muted(Theme.of(context))),
    ],
  );
}

/// The answers, wrapping as the pane narrows, then "Answer in the terminal"
/// at the row's end (board N1's spacer).
class _DockButtonRow extends StatelessWidget {
  const _DockButtonRow({required this.sessionId, required this.buttons});

  final String sessionId;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Wrap(
          spacing: Insets.sm,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: buttons,
        ),
      ),
      const SizedBox(width: Insets.sm),
      _AnswerInTerminal(sessionId: sessionId),
    ],
  );
}

/// The way to the terminal from the dock: in the terminal view it focuses the
/// pane the dock is under; in the chat it brings that pane back.
class _AnswerInTerminal extends ConsumerWidget {
  const _AnswerInTerminal({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      minimumSize: const Size(0, _dockButtonHeight),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_dockInnerRadius),
      ),
    ),
    onPressed: () => _openTerminal(ref, sessionId),
    child: const Text('Answer in the terminal'),
  );
}

/// One of the dock's answers: 28px, a 7px corner, amber for [primary] and
/// the raised tone otherwise, with the key it sends set as a key cap.
class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.label,
    required this.onPressed,
    this.keyHint,
    this.detail,
    this.tooltip,
    this.primary = false,
    this.wrap = false,
    super.key,
  });

  final String label;
  final String? keyHint;

  /// A literal after the label in the terminal's hand — the command prefix
  /// "Always allow" would stop asking about.
  final String? detail;
  final String? tooltip;
  final bool primary;

  /// Whether a long label wraps to a second line rather than ending in "…".
  final bool wrap;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final attention = SemanticColors.of(context).attention;
    // Ink on amber: near-black with a trace of the amber in it (the board's
    // #1a1405), in either theme — the amber is a light enough fill in both.
    final ink = Color.alphaBlend(
      Colors.black.withValues(alpha: 0.88),
      attention,
    );
    final hint = keyHint;
    final more = detail;
    final button = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: primary ? attention : tones.selected,
        foregroundColor: primary ? ink : scheme.onSurface,
        minimumSize: const Size(0, _dockButtonHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.xs,
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // Standard, not compact: compact takes eight pixels off the minimum
        // height, which drew the board's 28px buttons at about 22.
        visualDensity: VisualDensity.standard,
        textStyle: theme.textTheme.labelMedium?.copyWith(
          fontSize: _dockButtonFontSize,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_dockInnerRadius),
        ),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: wrap ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (more != null && more.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                more,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.small.copyWith(
                  color: primary ? ink : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (hint != null) ...[
            const SizedBox(width: 6),
            _KeyCap(
              label: hint,
              color: primary ? ink.withValues(alpha: 0.7) : scheme.outline,
              edge: primary ? ink.withValues(alpha: 0.35) : tones.floatingLine,
            ),
          ],
        ],
      ),
    );
    final message = tooltip;
    return message == null || message.isEmpty
        ? button
        : Tooltip(message: message, child: button);
  }
}

/// A key's name in a small outlined cap — what a dock button types.
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label, required this.color, required this.edge});

  final String label;
  final Color color;
  final Color edge;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
    decoration: BoxDecoration(
      border: Border.all(color: edge),
      borderRadius: BorderRadius.circular(Insets.xs),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}

/// The name of the key [keys] sends, for its cap — or null for a sequence
/// that has no one-word name, which then goes unlabelled rather than guessed.
String? _keyName(String keys) => switch (keys) {
  '\r' || '\n' => 'Enter',
  '\x1b' => 'Esc',
  '\t' => 'Tab',
  _ when keys.length == 1 && keys.codeUnitAt(0) > 0x20 => keys.toUpperCase(),
  _ => null,
};
