part of '../chat_transcript.dart';

/// How long ago a message was written, as of the list's last build.
class _MessageAge extends StatelessWidget {
  const _MessageAge({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) => Tooltip(
    // The age says how long ago; the moment itself is a hover away.
    message: messageMoment(at.toLocal()),
    child: Text(
      compactAge(_TranscriptNow.of(context).difference(at)),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// [at] as a person reads a moment: `Tue 7 Oct 2026, 18:07`.
String messageMoment(DateTime at) =>
    '${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]} '
    '${at.year}, ${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

/// Save-as-note, when notes are on, then Copy, then Copy turn where offered,
/// then the [turn]'s own actions. On touch a turn's actions, Copy turn and
/// Save as note go behind one ⋯ beside Copy.
List<Widget> _messageActions(
  VoidCallback? onSaveNote,
  String copyText, {
  String Function()? copyTurn,
  List<_TurnAction> turn = const [],
}) => [
  _MessageActions(
    onSaveNote: onSaveNote,
    copyText: copyText,
    copyTurn: copyTurn,
    turn: turn,
  ),
];

class _MessageActions extends StatelessWidget {
  const _MessageActions({
    required this.onSaveNote,
    required this.copyText,
    required this.copyTurn,
    required this.turn,
  });

  final VoidCallback? onSaveNote;
  final String copyText;
  final String Function()? copyTurn;
  final List<_TurnAction> turn;

  @override
  Widget build(BuildContext context) {
    final save = onSaveNote;
    final copyTurn = this.copyTurn;
    if (turn.isNotEmpty && UiDensity.of(context).isTouch) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CopyButton(text: copyText),
          _TurnMoreButton(
            actions: turn,
            extra: [
              _TurnAction(
                id: 'copy-plain',
                label: 'Copy as plain text',
                icon: AppIcons.article,
                run: (context) async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await Clipboard.setData(
                    ClipboardData(text: markdownPlainText(copyText)),
                  );
                  messenger?.showSnackBar(
                    const SnackBar(content: Text('Text copied to clipboard')),
                  );
                },
              ),
              if (copyTurn != null)
                _TurnAction(
                  id: 'copy-turn',
                  label: 'Copy turn',
                  icon: AppIcons.clipboardText,
                  run: (context) async {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    await Clipboard.setData(ClipboardData(text: copyTurn()));
                    messenger?.showSnackBar(
                      const SnackBar(content: Text('Turn copied.')),
                    );
                  },
                ),
              if (save != null)
                _TurnAction(
                  id: 'save-note',
                  label: 'Save as note',
                  icon: AppIcons.notePencil,
                  run: (_) async => save(),
                ),
            ],
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (save != null) _SaveNoteButton(onSave: save),
        _CopyButton(text: copyText),
        _ConfirmingIconButton(
          key: const ValueKey('chat-copy-plain'),
          icon: AppIcons.article,
          tooltip: 'Copy as plain text',
          confirmedTooltip: 'Copied',
          onPressed: () => Clipboard.setData(
            ClipboardData(text: markdownPlainText(copyText)),
          ),
        ),
        if (copyTurn != null)
          _ConfirmingIconButton(
            key: const ValueKey('chat-copy-turn'),
            icon: AppIcons.clipboardText,
            tooltip: 'Copy turn',
            confirmedTooltip: 'Copied',
            onPressed: () => Clipboard.setData(ClipboardData(text: copyTurn())),
          ),
        for (final action in turn) _TurnIconButton(action: action),
      ],
    );
  }
}

/// Glyph, eyebrow and actions: a tool card's header row. The user's and the
/// agent's turns have none (board N2); their age and actions show on hover.
class _MessageHeader extends StatelessWidget {
  const _MessageHeader({
    required this.icon,
    required this.label,
    required this.color,
    this.fullLabel,
    this.badge,
    this.actions = const [],
  });

  final IconData icon;
  final String label;
  final Color color;

  /// The untruncated name, offered as a tooltip when [label] shortens it.
  final String? fullLabel;

  /// A marker right after the eyebrow, such as a failed call's.
  final Widget? badge;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // The shared header at the pointer's sizes, its defaults.
    return TranscriptRoleHeader(
      icon: icon,
      label: label,
      color: color,
      fullLabel: fullLabel,
      badge: badge,
      actions: actions,
    );
  }
}

/// A turn's age and its actions, drawn only while the pointer is over the turn
/// or focus is inside it (board N2: no name row above a message). Always laid
/// out and always in the semantics tree, so the row never shifts when it shows
/// and a screen reader or a keyboard user reaches Copy without hovering.
class _TurnMeta extends StatelessWidget {
  const _TurnMeta({
    required this.shown,
    required this.at,
    required this.actions,
    this.touch = false,
  });

  final bool shown;
  final DateTime? at;
  final List<Widget> actions;

  /// At touch density the meta takes no room until shown: laid out hidden,
  /// its 48dp buttons would put a blank band under every turn.
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final at = this.at;
    if (touch && !shown) return const SizedBox.shrink();
    return SelectionContainer.disabled(
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: Motion.of(context).fast,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (at != null) ...[
              _MessageAge(at: at),
              const SizedBox(width: Insets.xs),
            ],
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// A turn's body with its [_TurnMeta] beside it: at the end of the row where
/// the pane is wide, so the meta costs no height, and under the body where it
/// is narrow, so it costs the words none of their width.
class _TurnWithMeta extends StatefulWidget {
  const _TurnWithMeta({
    required this.body,
    required this.at,
    required this.actions,
    this.alignEnd = false,
  });

  final Widget body;
  final DateTime? at;
  final List<Widget> actions;

  /// The user's side: the body hugs the end and the meta sits before it.
  final bool alignEnd;

  @override
  State<_TurnWithMeta> createState() => _TurnWithMetaState();
}

/// Its own hover and focus state, so a pointer crossing a turn redraws that
/// turn's meta and never reaches the row cache above it.
class _TurnWithMetaState extends State<_TurnWithMeta> {
  /// Below this the meta goes under the body rather than beside it.
  static const _wideTurn = 480.0;

  bool _hovered = false;
  bool _focused = false;

  void _set({bool? hovered, bool? focused}) {
    final h = hovered ?? _hovered;
    final f = focused ?? _focused;
    if (h == _hovered && f == _focused) return;
    setState(() {
      _hovered = h;
      _focused = f;
    });
  }

  /// Touch: a tap shows this turn's meta until another turn is tapped, or
  /// this one again. Long-press stays the selection area's.
  Widget _buildTouch(ValueNotifier<Object?> tapped) {
    final end = widget.alignEnd;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => tapped.value = identical(tapped.value, this) ? null : this,
      child: Column(
        crossAxisAlignment: end
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          widget.body,
          ValueListenableBuilder<Object?>(
            valueListenable: tapped,
            builder: (context, value, _) => _TurnMeta(
              shown: identical(value, this),
              at: widget.at,
              actions: widget.actions,
              touch: true,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tapped = _TappedTurn.of(context);
    if (tapped != null && UiDensity.of(context).isTouch) {
      return _buildTouch(tapped);
    }
    final meta = _TurnMeta(
      shown: _hovered || _focused,
      at: widget.at,
      actions: widget.actions,
    );
    final end = widget.alignEnd;
    return MouseRegion(
      onEnter: (_) => _set(hovered: true),
      onExit: (_) => _set(hovered: false),
      // Listens for a descendant taking focus; never a stop of its own.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => _set(focused: focused),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < _wideTurn) {
              return Column(
                crossAxisAlignment: end
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [widget.body, meta],
              );
            }
            return Row(
              mainAxisAlignment: end
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              crossAxisAlignment: end
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: end
                  // Flexible: at the narrow end of wide the bubble's share
                  // plus the meta can exceed the row, and the bubble gives.
                  ? [
                      meta,
                      const SizedBox(width: Insets.xs),
                      Flexible(child: widget.body),
                    ]
                  : [
                      Expanded(child: widget.body),
                      const SizedBox(width: Insets.sm),
                      meta,
                    ],
            );
          },
        ),
      ),
    );
  }
}

/// Keeps this message as a note, in one tap: its own words, nothing summarised
/// and no dialog — you were mid-thought. Titling lives in the Notes panel.
class _SaveNoteButton extends StatelessWidget {
  const _SaveNoteButton({required this.onSave});
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => _ConfirmingIconButton(
    icon: AppIcons.notePencil,
    tooltip: 'Save as note',
    confirmedTooltip: 'Saved to Notes',
    onPressed: () async => onSave(),
  );
}

/// A low-emphasis copy-to-clipboard button shown on each message.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => _ConfirmingIconButton(
    icon: AppIcons.copySimple,
    tooltip: 'Copy message',
    confirmedTooltip: 'Copied',
    onPressed: () => Clipboard.setData(ClipboardData(text: text)),
  );
}

/// A row action that shows a check for a moment once [onPressed] has done its
/// work. The moment ends with the row: a closed session leaves no timer.
class _ConfirmingIconButton extends StatefulWidget {
  const _ConfirmingIconButton({
    required this.icon,
    required this.tooltip,
    required this.confirmedTooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final String confirmedTooltip;
  final Future<void> Function() onPressed;

  @override
  State<_ConfirmingIconButton> createState() => _ConfirmingIconButtonState();
}

class _ConfirmingIconButtonState extends State<_ConfirmingIconButton> {
  static const _confirmFor = Duration(seconds: 2);
  Timer? _settle;

  bool get _confirmed => _settle?.isActive ?? false;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  Future<void> _press() async {
    await widget.onPressed();
    if (!mounted) return;
    _settle?.cancel();
    setState(() {
      _settle = Timer(_confirmFor, () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final confirmed = _confirmed;
    final touch = UiDensity.of(context).isTouch;
    final floor = touch ? Touch.target : 24.0;
    return IconButton(
      tooltip: confirmed ? widget.confirmedTooltip : widget.tooltip,
      visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
      iconSize: touch ? Touch.icon : Chrome.iconSmall,
      constraints: BoxConstraints(minWidth: floor, minHeight: floor),
      padding: EdgeInsets.zero,
      color: confirmed
          ? SemanticColors.of(context).idle
          : Theme.of(context).colorScheme.onSurfaceVariant,
      icon: Icon(confirmed ? AppIcons.check : widget.icon),
      onPressed: _press,
    );
  }
}
