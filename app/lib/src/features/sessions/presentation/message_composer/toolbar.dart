// The composer's toolbar: attach, snippets, send and stop.

part of '../message_composer.dart';

/// Attach, snippets, any chips a host adds, and the round send at the far
/// end. At a pane's narrowest the chips take a row to themselves.
class _ComposerToolbar extends StatelessWidget {
  const _ComposerToolbar({
    required this.chips,
    required this.attaches,
    required this.onAttach,
    required this.snippets,
    required this.send,
    required this.touch,
  });

  static const rowMinWidth = 380.0;

  final List<Widget> chips;

  /// False hides Attach altogether.
  final bool attaches;

  /// Null while the composer cannot take input.
  final VoidCallback? onAttach;

  /// The snippets button, when the host offers a library.
  final Widget? snippets;
  final Widget send;

  /// Attach takes any file, and every control is a thumb's size.
  final bool touch;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tools = [
        if (attaches)
          _ToolbarIconButton(
            tooltip: touch
                ? 'Attach a file'
                : 'Attach a file (paste an image with Ctrl+V)',
            icon: AppIcons.plus,
            touch: touch,
            onPressed: onAttach,
          ),
        ?snippets,
      ];

      if (constraints.maxWidth > rowMinWidth || chips.isEmpty) {
        return Row(
          children: [
            ...tools,
            if (chips.isNotEmpty)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                  child: Wrap(
                    spacing: Insets.xs,
                    runSpacing: Insets.xs,
                    children: chips,
                  ),
                ),
              )
            else
              const Spacer(),
            send,
          ],
        );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [...tools, const Spacer(), send]),
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: chips,
            ),
          ),
        ],
      );
    },
  );
}

/// A quiet toolbar glyph (board N2's 26 by 22 tab button): muted, a wash
/// under the pointer, no fill of its own. [touch] makes it a thumb's 48dp.
class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.touch,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool touch;

  /// Shared with the snippets menu button, which is not an [IconButton].
  static ButtonStyle styleOf(BuildContext context, {bool touch = false}) =>
      IconButton.styleFrom(
        // `VisualDensity.compact` is already the app-wide default; restating
        // it subtracted its 8px twice and left the button 18 logical pixels
        // tall.
        visualDensity: VisualDensity.standard,
        minimumSize: Size.square(touch ? Touch.target : Chrome.control),
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      );

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: styleOf(context, touch: touch),
    iconSize: touch ? Touch.icon : Chrome.icon,
    icon: Icon(icon),
  );
}

/// The snippet library, read when it opens. Picking one types it into the
/// box at the caret, unsent. A menu under a pointer, a sheet under a thumb.
class _SnippetsButton extends StatelessWidget {
  const _SnippetsButton({
    required this.snippets,
    required this.onPicked,
    required this.touch,
  });

  final List<ComposerSnippet> Function() snippets;

  /// Null while the composer cannot take input.
  final ValueChanged<String>? onPicked;
  final bool touch;

  static const _empty = 'No snippets yet — add them in Settings › Snippets';

  Future<void> _showSheet(
    BuildContext context,
    ValueChanged<String> onPicked,
  ) async {
    final list = snippets();
    final picked = await showAdaptiveModal<String>(
      context: context,
      title: 'Insert a snippet',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (list.isEmpty)
            const ListTile(
              minTileHeight: Touch.target,
              enabled: false,
              leading: Icon(AppIcons.code, size: Touch.icon),
              title: Text(_empty),
            ),
          for (final snippet in list)
            ListTile(
              minTileHeight: Touch.target,
              leading: const Icon(AppIcons.code, size: Touch.icon),
              title: Text(snippet.label),
              onTap: () => Navigator.of(context).pop(snippet.text),
            ),
        ],
      ),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final onPicked = this.onPicked;
    if (touch) {
      return _ToolbarIconButton(
        tooltip: 'Insert a snippet',
        icon: AppIcons.code,
        touch: true,
        onPressed: onPicked == null
            ? null
            : () => unawaited(_showSheet(context, onPicked)),
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Insert a snippet',
      enabled: onPicked != null,
      onSelected: onPicked,
      itemBuilder: (context) {
        final list = snippets();
        if (list.isEmpty) {
          return [
            DesktopMenuItem<String>(
              value: '',
              label: _empty,
              icon: AppIcons.code,
              enabled: false,
            ),
          ];
        }
        return [
          for (final snippet in list)
            DesktopMenuItem<String>(
              value: snippet.text,
              label: snippet.label,
              icon: AppIcons.code,
            ),
        ];
      },
      icon: const Icon(AppIcons.code),
      iconSize: Chrome.icon,
      // The same quiet glyph as Attach beside it.
      style: _ToolbarIconButton.styleOf(context),
    );
  }
}

/// Send, and the one thing in the composer that knows what has been typed. Its
/// own widget so a keystroke rebuilds one button, not the composer. Board N2
/// draws it as a round accent button at the toolbar's far end.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.input,
    required this.attachments,
    required this.busy,
    required this.onSend,
    required this.touch,
    this.queued = false,
  });

  /// Files picked on a phone and waiting to be uploaded by this press.
  final bool queued;

  /// Board N2's 30px circle; a thumb's 48dp at touch density, where it is the
  /// only way to send — a soft keyboard's Enter is a new line.
  static double diameterFor({required bool touch}) =>
      touch ? Touch.target : 30.0;

  final TextEditingController input;
  final List<_Attachment> attachments;
  final bool busy;
  final bool touch;

  /// Null when the composer cannot send at all — disabled, or mid-send.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diameter = diameterFor(touch: touch);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: input,
      builder: (context, value, _) {
        final ready =
            onSend != null &&
            (value.text.trim().isNotEmpty || attachments.isNotEmpty || queued);
        return IconButton.filled(
          // Named, because it is icon-only and Narrator reads the semantics
          // tree. The chord is in the label as the only place that says so.
          tooltip: busy
              ? 'Sending…'
              : touch
              ? 'Send'
              : 'Send (Enter) · Shift + Enter for a new line',
          onPressed: onSend,
          iconSize: touch ? Touch.icon : Chrome.iconAction,
          style: IconButton.styleFrom(
            visualDensity: VisualDensity.standard,
            padding: EdgeInsets.zero,
            fixedSize: Size.square(diameter),
            minimumSize: Size.square(diameter),
            shape: const CircleBorder(),
            backgroundColor: ready
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            foregroundColor: ready ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          icon: busy ? const InlineSpinner() : const Icon(AppIcons.arrowUp),
        );
      },
    );
  }
}

/// Stop (■) in Send's place while the agent works, as Claude, ChatGPT and
/// Codex draw it; the same circle, so the box does not jump.
class _StopButton extends StatelessWidget {
  const _StopButton({required this.touch, required this.onStop});

  final bool touch;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diameter = _SendButton.diameterFor(touch: touch);
    return Semantics(
      button: true,
      label: 'Stop the running turn',
      excludeSemantics: true,
      child: IconButton.filled(
        key: const ValueKey('composer-stop'),
        // A phone has no Esc to name.
        tooltip: touch ? 'Stop' : 'Stop · Esc',
        onPressed: onStop,
        iconSize: touch ? Touch.icon : Chrome.iconAction,
        style: IconButton.styleFrom(
          visualDensity: VisualDensity.standard,
          padding: EdgeInsets.zero,
          fixedSize: Size.square(diameter),
          minimumSize: Size.square(diameter),
          shape: const CircleBorder(),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
        icon: const Icon(AppIcons.stopFill),
      ),
    );
  }
}
