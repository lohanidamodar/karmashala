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

/// The session message box: text plus image attachments. On send the images are
/// saved and their paths appended, so the agent can read them.
class MessageComposer extends StatefulWidget {
  const MessageComposer({
    required this.onSend,
    required this.hintText,
    this.enabled = true,
    this.chips = const [],
    this.controller,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canType = widget.enabled && !_busy;
    final textScaler = MediaQuery.textScalerOf(context);

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
                  hintText: widget.hintText,
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(height: 1),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Chrome.chatWidth,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.sm),
                    // Only the border listens to focus: a click into the box
                    // must not rebuild the field it landed in.
                    child: ListenableBuilder(
                      listenable: _focusNode,
                      builder: (context, child) => AnimatedContainer(
                        duration: Motion.of(context).fast,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(Radii.lg),
                          // The accent border is the whole focus signal. The
                          // 1.0→1.5 width it also grew relaid the composer
                          // out on every focus.
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
              ),
            ],
          ),
        );
      },
    );
  }

  /// Everything but the text lines, near enough to size the box by: guessing
  /// low costs a few pixels of scroll, never an overflow.
  double _chromeHeight(double width, TextScaler textScaler) {
    // Divider, card padding and border, the text's own padding, the toolbar.
    var height =
        1 + 2 * Insets.sm + 2 + 2 * Insets.sm + Chrome.control + Insets.sm;
    final toolbarWidth =
        math.min(width, Chrome.chatWidth) - 4 * Insets.sm - 2;
    if (widget.chips.isNotEmpty &&
        toolbarWidth <= _ComposerToolbar.rowMinWidth) {
      height += Insets.xs + Chrome.control;
    }
    if (_attachments.isNotEmpty) {
      height +=
          Insets.sm +
          _Thumbnail.extent +
          Insets.xs +
          textScaler.scale(11) * 1.5;
    }
    return height;
  }
}

/// The thumbnails, and the one line explaining where the files went. Drawn
/// always, it cost 31 of the composer's 113px for a usually-false sentence.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.attachments, required this.onRemove});

  final List<_Attachment> attachments;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              for (var i = 0; i < attachments.length; i++)
                _Thumbnail(
                  bytes: attachments[i].bytes,
                  onRemove: () => onRemove(i),
                ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Saved to a temp folder and sent to the agent as file paths.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Attach, the session's chips, and send. At a pane's narrowest the three
/// cannot share a row, so the chips take one to themselves.
class _ComposerToolbar extends StatelessWidget {
  const _ComposerToolbar({
    required this.chips,
    required this.onAttach,
    required this.send,
  });

  static const rowMinWidth = 380.0;

  final List<Widget> chips;

  /// Null while the composer cannot take input.
  final VoidCallback? onAttach;
  final Widget send;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final attach = IconButton(
        tooltip: 'Attach image (or paste with Ctrl+V)',
        onPressed: onAttach,
        // `VisualDensity.compact` is already the app-wide default; restating it
        // subtracted its 8px twice and left both buttons 18 logical pixels tall.
        style: IconButton.styleFrom(
          visualDensity: VisualDensity.standard,
          minimumSize: const Size.square(Chrome.control),
        ),
        icon: const Icon(AppIcons.image),
      );

      if (constraints.maxWidth > rowMinWidth) {
        return Row(
          children: [
            attach,
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
          Row(children: [attach, const Spacer(), send]),
          if (chips.isNotEmpty)
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

/// Send, and the one thing in the composer that knows what has been typed. Its
/// own widget so a keystroke rebuilds a 26px button, not the composer.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.input,
    required this.attachments,
    required this.busy,
    required this.onSend,
  });

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
          style: IconButton.styleFrom(
            visualDensity: VisualDensity.standard,
            minimumSize: const Size.square(Chrome.control),
            backgroundColor: ready
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            foregroundColor: ready ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          icon: busy
              ? const InlineSpinner()
              : const Icon(AppIcons.paperPlaneRight),
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.bytes, required this.onRemove});
  final Uint8List bytes;
  final VoidCallback onRemove;

  static const _image = 56.0;

  /// How far the remove button hangs past the image's corner.
  static const _overhang = 6.0;

  /// The thumbnail's full height, overhang included.
  static const extent = _image + _overhang;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The overhang is padding inside the Stack rather than a negative offset
    // out of it: a Stack only hit-tests its own bounds, so the part of the
    // button drawn outside them could not be clicked.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: _overhang, right: _overhang),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Image.memory(
              bytes,
              width: _image,
              height: _image,
              fit: BoxFit.cover,
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: 'Remove',
            iconSize: Chrome.iconAction,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              backgroundColor: scheme.surfaceContainerHighest,
            ),
            icon: const Icon(AppIcons.x),
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }
}
