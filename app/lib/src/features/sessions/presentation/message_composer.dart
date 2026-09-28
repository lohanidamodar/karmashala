import 'package:karmashala_core/logging.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/menus.dart';

/// How many lines of [style] fit [height], between 1 and 12. Unbounded means
/// the composer's full twelve.
@visibleForTesting
int composerLinesThatFit(
  double height, {
  required TextStyle? style,
  required TextScaler textScaler,
}) {
  const most = 12;
  if (!height.isFinite) return most;
  final painter = TextPainter(
    text: TextSpan(text: ' ', style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout();
  final line = painter.preferredLineHeight;
  painter.dispose();
  return (height / line).floor().clamp(1, most);
}

/// A pasted/attached image, kept on disk so its path can be handed to the agent.
class _Attachment {
  _Attachment(this.file, this.bytes);
  final File file;
  final Uint8List bytes;
}

/// One entry of the composer's snippets menu: what it is called, and the text
/// it puts in the box. Plain values, so the composer knows nothing of where
/// the library lives.
class ComposerSnippet {
  const ComposerSnippet({required this.label, required this.text});

  final String label;
  final String text;
}

/// The session message box: text plus image attachments. On send the images are
/// saved and their paths appended, so the agent can read them.
///
/// Board N2 draws it as **one object**: the attachment chips, the text, and a
/// toolbar of attach, snippets and a round send, inside one rounded card. It
/// holds nothing else — mode, model and the view switch are the pane's status
/// line's (owner, 2026-09-28: one place per control).
class MessageComposer extends StatefulWidget {
  const MessageComposer({
    required this.onSend,
    required this.hintText,
    this.enabled = true,
    this.chips = const [],
    this.controller,
    this.snippets,
    super.key,
  });

  /// Sends the composed message (text + appended image paths). Awaited so the
  /// composer can show a busy state.
  final Future<void> Function(String text) onSend;
  final String hintText;
  final bool enabled;

  /// Controls shown in a row beneath the text box. A slot rather than a widget
  /// this class builds, so the composer keeps knowing nothing about sessions.
  final List<Widget> chips;

  /// The text box's controller, when the caller needs to put something in it.
  /// Supplied means owned: the caller disposes it, else the composer does.
  final TextEditingController? controller;

  /// The snippets the toolbar's menu offers, read each time it opens. Null
  /// hides the button: a host with no library has nothing to offer.
  final List<ComposerSnippet> Function()? snippets;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  static final _log = AppLogger.named('composer');

  late TextEditingController _input;
  final _attachments = <_Attachment>[];
  bool _busy = false;
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _handleKey);

  @override
  void initState() {
    super.initState();
    // No listener on [_input] or [_focusNode] here: [_SendButton] and the
    // card's border listen for themselves, so neither rebuilds the text field.
    _input = widget.controller ?? TextEditingController();
  }

  @override
  void didUpdateWidget(MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _input.dispose();
      }
      _input = widget.controller ?? TextEditingController();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    if (widget.controller == null) _input.dispose();
    super.dispose();
  }

  /// Enter sends, Shift+Enter inserts a newline, and Ctrl/Cmd+V also attaches a
  /// clipboard image when one is present (text paste still proceeds).
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (keys.isControlPressed || keys.isMetaPressed)) {
      _pasteImageIfAny();
      return KeyEventResult.ignored;
    }
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (isEnter && !keys.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Ctrl/Cmd+V also attaches a clipboard image when there is one.
  ///
  /// **It used to swallow every failure**, so a paste that did not attach left
  /// nothing behind — not a message, not a log line — and there was no way to
  /// tell a clipboard holding no image from one that could not be read. Both
  /// now say so, and only the second is an error.
  Future<void> _pasteImageIfAny() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final img = await Pasteboard.image;
      if (img != null && img.isNotEmpty) {
        await _addImageBytes(img);
        return;
      }
      _log.debug('Paste: the clipboard holds no image.');
    } on Object catch (error, stack) {
      _log.warning('Paste: the clipboard could not be read.', error, stack);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('That image could not be pasted: $error')),
      );
    }
  }

  Future<Directory> _attachmentsDir() async {
    final dir = Directory(
      '${Directory.systemTemp.path}/karmashala/attachments',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _addImageBytes(Uint8List bytes, {String ext = 'png'}) async {
    final dir = await _attachmentsDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File('${dir.path}/img_$stamp.$ext');
    await file.writeAsBytes(bytes);
    if (mounted) setState(() => _attachments.add(_Attachment(file, bytes)));
  }

  /// The user's pictures, when there is such a folder; the picker falls back
  /// to somewhere local either way.
  String? _pictures() {
    final home = Platform.environment['USERPROFILE'];
    return home == null || home.isEmpty ? null : '$home\\Pictures';
  }

  Future<void> _attach() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Prefer an image already on the clipboard ("paste image").
      final clip = await Pasteboard.image;
      if (clip != null && clip.isNotEmpty) {
        await _addImageBytes(clip);
        return;
      }
      // Otherwise let the user pick an image file. The clipboard read above
      // yields, so the composer may already be gone.
      if (!mounted) return;
      final file = await pickOneFile(
        context: context,
        what: 'an image to attach',
        // The composer knows nothing about sessions, so the nearest useful
        // place is the user's own pictures.
        startNear: _pictures(),
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Images',
            extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
          ),
        ],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final ext = file.name.contains('.')
          ? file.name.split('.').last.toLowerCase()
          : 'png';
      await _addImageBytes(bytes, ext: ext);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not attach image: $e')),
      );
    }
  }

  Future<void> _send() async {
    if (_busy || !widget.enabled) return;
    final text = _input.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    final buffer = StringBuffer(text);
    if (_attachments.isNotEmpty) {
      buffer.write(text.isEmpty ? '' : '\n\n');
      buffer.write('Attached image(s):');
      for (final a in _attachments) {
        buffer.write('\n');
        buffer.write(a.file.path);
      }
    }

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onSend(buffer.toString());
      if (mounted) {
        _input.clear();
        setState(_attachments.clear);
      }
    } catch (e) {
      // Keep the text/attachments so the user can retry.
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Puts a snippet's text where the caret is, replacing any selection, and
  /// leaves it unsent: a snippet is a start on a message, not a message.
  void _insertSnippet(String text) {
    final value = _input.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _input.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canType = widget.enabled && !_busy;
    final textScaler = MediaQuery.textScalerOf(context);
    final snippets = widget.snippets;
    final hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return LayoutBuilder(
      builder: (context, box) {
        // As many lines as the pane leaves room for. The scroll view is the
        // last resort for a pane shorter than the chrome itself.
        final maxLines = composerLinesThatFit(
          box.maxHeight - _chromeHeight(box.maxWidth, textScaler),
          style: theme.textTheme.bodyMedium,
          textScaler: textScaler,
        );
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_attachments.isNotEmpty)
              _AttachmentStrip(
                attachments: _attachments,
                onRemove: (i) => setState(() => _attachments.removeAt(i)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: TextField(
                controller: _input,
                focusNode: _focusNode,
                enabled: canType,
                // **Three lines at rest, not one.** The glyphs got 19 of the
                // composer's 113 logical pixels. Fewer only when the pane has
                // no room for three.
                minLines: math.min(3, maxLines),
                maxLines: maxLines,
                textInputAction: TextInputAction.newline,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  // `filled` is on in the app's theme, and with no border it
                  // painted a rectangle inside this card.
                  filled: false,
                  border: InputBorder.none,
                  // The wrapper above already spends `Insets.sm` vertically;
                  // a second helping here paid twice.
                  contentPadding: EdgeInsets.zero,
                  // Board N2: the prompt, then the keys in a dimmer voice.
                  // Two texts in a wrap rather than one span, so a narrow pane
                  // puts the keys on the next line instead of clipping them.
                  hint: Wrap(
                    children: [
                      Text(widget.hintText, style: hintStyle),
                      Text(
                        ' (Enter sends · Shift Enter new line)',
                        style: hintStyle?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: _dimAlpha,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.sm,
                0,
                Insets.sm,
                Insets.sm,
              ),
              child: _ComposerToolbar(
                chips: widget.chips,
                onAttach: canType ? _attach : null,
                snippets: snippets == null
                    ? null
                    : _SnippetsButton(
                        snippets: snippets,
                        onPicked: canType ? _insertSnippet : null,
                      ),
                send: _SendButton(
                  input: _input,
                  attachments: _attachments,
                  busy: _busy,
                  onSend: canType ? _send : null,
                ),
              ),
            ),
          ],
        );
        return SingleChildScrollView(
          primary: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Chrome.chatWidth),
            child: Padding(
              // No side padding: the chat's gutter already places it, so its
              // edges line up with the messages above (board N2).
              padding: const EdgeInsets.only(bottom: Insets.md),
              // Only the ring listens to focus: a click into the box must not
              // rebuild the field it landed in.
              child: ListenableBuilder(
                listenable: _focusNode,
                builder: (context, child) => AnimatedContainer(
                  duration: Motion.of(context).fast,
                  decoration: BoxDecoration(
                    color: SurfaceTones.of(context).raised,
                    borderRadius: BorderRadius.circular(_radius),
                    // Board N2's 1px ring; the accent is the whole focus
                    // signal. The 1.0→1.5 width it also grew relaid the
                    // composer out on every focus.
                    border: Border.all(
                      color: _focusNode.hasFocus
                          ? scheme.primary
                          : scheme.outlineVariant,
                    ),
                  ),
                  child: child,
                ),
                child: body,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Board N2's card corner: 12px, between the row radius and the dialog's.
  static const _radius = Radii.md + Insets.hair * 2;

  /// The key hint's share of the muted colour: board N2's `--dim` under
  /// `--mut`, as a fraction rather than a second grey.
  static const _dimAlpha = 0.7;

  /// Everything but the text lines, near enough to size the box by: guessing
  /// low costs a few pixels of scroll, never an overflow.
  double _chromeHeight(double width, TextScaler textScaler) {
    // Bottom padding, the ring, the text's own padding, the toolbar.
    var height =
        Insets.md + 2 + 2 * Insets.sm + _SendButton.diameter + Insets.sm;
    final toolbarWidth = width - 2 * Insets.sm - 2;
    if (widget.chips.isNotEmpty &&
        toolbarWidth <= _ComposerToolbar.rowMinWidth) {
      height += Insets.xs + Chrome.control;
    }
    if (_attachments.isNotEmpty) {
      height += Insets.sm + _AttachmentChip.height;
    }
    return height;
  }
}

/// The attachments as board N2 draws them: a row of pills, each an image
/// glyph, the file's name and a remove button. Where the files go is the
/// pill's tooltip — a sentence under them, always drawn, cost 31px.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.attachments, required this.onRemove});

  final List<_Attachment> attachments;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 0),
    child: Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        for (var i = 0; i < attachments.length; i++)
          _AttachmentChip(
            name: attachments[i].file.uri.pathSegments.last,
            onRemove: () => onRemove(i),
          ),
      ],
    ),
  );
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.name, required this.onRemove});

  final String name;
  final VoidCallback onRemove;

  /// The pill's height, which the composer's sizing counts.
  static const height = Chrome.control;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Tooltip(
      message: 'Saved to a temp folder and sent to the agent as a file path.',
      child: Container(
        height: height,
        padding: const EdgeInsets.only(left: Insets.sm),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.image, size: Chrome.iconSmall, color: muted),
            const SizedBox(width: Insets.xs),
            ConstrainedBox(
              // A long generated name gives way before the remove button.
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              iconSize: Chrome.iconSmall,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                minWidth: height,
                minHeight: height,
              ),
              padding: EdgeInsets.zero,
              color: muted,
              icon: const Icon(AppIcons.x),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// Attach, snippets, any chips a host adds, and the round send at the far
/// end. At a pane's narrowest the chips take a row to themselves.
class _ComposerToolbar extends StatelessWidget {
  const _ComposerToolbar({
    required this.chips,
    required this.onAttach,
    required this.snippets,
    required this.send,
  });

  static const rowMinWidth = 380.0;

  final List<Widget> chips;

  /// Null while the composer cannot take input.
  final VoidCallback? onAttach;

  /// The snippets button, when the host offers a library.
  final Widget? snippets;
  final Widget send;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tools = [
        _ToolbarIconButton(
          tooltip: 'Attach image (or paste with Ctrl+V)',
          icon: AppIcons.image,
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
/// under the pointer, no fill of its own.
class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  /// Shared with the snippets menu button, which is not an [IconButton].
  static ButtonStyle styleOf(BuildContext context) => IconButton.styleFrom(
    // `VisualDensity.compact` is already the app-wide default; restating it
    // subtracted its 8px twice and left the button 18 logical pixels tall.
    visualDensity: VisualDensity.standard,
    minimumSize: const Size.square(Chrome.control),
    foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.sm),
    ),
  );

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: styleOf(context),
    iconSize: Chrome.icon,
    icon: Icon(icon),
  );
}

/// The snippet library as a menu, read when it opens. Picking one types it
/// into the box at the caret, unsent.
class _SnippetsButton extends StatelessWidget {
  const _SnippetsButton({required this.snippets, required this.onPicked});

  final List<ComposerSnippet> Function() snippets;

  /// Null while the composer cannot take input.
  final ValueChanged<String>? onPicked;

  @override
  Widget build(BuildContext context) {
    final onPicked = this.onPicked;
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
              label: 'No snippets yet — add them in Settings › Snippets',
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
  });

  /// Board N2's 30px circle.
  static const diameter = 30.0;

  final TextEditingController input;
  final List<_Attachment> attachments;
  final bool busy;

  /// Null when the composer cannot send at all — disabled, or mid-send.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: input,
      builder: (context, value, _) {
        final ready =
            onSend != null &&
            (value.text.trim().isNotEmpty || attachments.isNotEmpty);
        return IconButton.filled(
          // Named, because it is icon-only and Narrator reads the semantics
          // tree. The chord is in the label as the only place that says so.
          tooltip: busy
              ? 'Sending…'
              : 'Send (Enter) · Shift + Enter for a new line',
          onPressed: onSend,
          iconSize: Chrome.iconAction,
          style: IconButton.styleFrom(
            visualDensity: VisualDensity.standard,
            padding: EdgeInsets.zero,
            fixedSize: const Size.square(diameter),
            minimumSize: const Size.square(diameter),
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
