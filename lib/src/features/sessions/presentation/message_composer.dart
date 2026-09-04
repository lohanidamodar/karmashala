import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/file_picking.dart';

/// A pasted/attached image, kept on disk so its path can be handed to the agent.
class _Attachment {
  _Attachment(this.file, this.bytes);
  final File file;
  final Uint8List bytes;
}

/// The session message box: text plus image attachments. Paste an image from the
/// clipboard (or pick a file); on send, the images are saved and their paths are
/// appended to the message so the agent can read them.
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

  /// Controls shown in a row beneath the text box — the permission mode, and
  /// whatever the model/effort chips become. A slot rather than a widget this
  /// class builds, so the composer keeps knowing nothing about sessions.
  final List<Widget> chips;

  /// The text box's controller, when the caller needs to put something in it —
  /// a note being sent back to this session. Supplied means owned: the caller
  /// disposes it. Omitted, the composer makes and disposes its own.
  final TextEditingController? controller;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  late TextEditingController _input;
  final _attachments = <_Attachment>[];
  bool _busy = false;
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _handleKey);

  @override
  void initState() {
    super.initState();
    _input = widget.controller ?? TextEditingController();
    _focusNode.addListener(_onFocusChange);
  }

  /// Focus decides the card's border colour, and changes once per click rather
  /// than once per character — so this one may rebuild the composer.
  ///
  /// **There is deliberately no listener on [_input].** One existed, and it
  /// called `setState` for every keystroke so the send button could recolour:
  /// the whole composer subtree — the card, the field's wrapper, the toolbar's
  /// `LayoutBuilder`, both buttons, the chip row — rebuilt per character, in
  /// the widget the user types into most. [_SendButton] listens to the
  /// controller itself instead, so a character now rebuilds one button.
  void _onFocusChange() {
    if (mounted) setState(() {});
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
    _focusNode.removeListener(_onFocusChange);
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

  Future<void> _pasteImageIfAny() async {
    try {
      final img = await Pasteboard.image;
      if (img != null && img.isNotEmpty) await _addImageBytes(img);
    } catch (_) {}
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

  Future<void> _attach() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Prefer an image already on the clipboard ("paste image").
      final clip = await Pasteboard.image;
      if (clip != null && clip.isNotEmpty) {
        await _addImageBytes(clip);
        return;
      }
      // Otherwise let the user pick an image file.
      final file = await pickOneFile(
        what: 'an image to attach',
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
            child: Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: AnimatedContainer(
                duration: Motion.fast,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  // The accent border is the whole focus signal. It used to
                  // also grow from 1.0 to 1.5 and light a `primary` glow: the
                  // width change relaid the composer out — and so nudged the
                  // transcript — every time the box took or lost focus, and
                  // the glow was a second mechanism saying the one thing the
                  // colour already says. `inputDecorationTheme` marks focus
                  // the same way, so every field in the app now agrees.
                  border: Border.all(
                    color: _focusNode.hasFocus
                        ? scheme.primary
                        : scheme.outlineVariant,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_attachments.isNotEmpty) _attachmentStrip(theme),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.md,
                        vertical: Insets.sm,
                      ),
                      child: TextField(
                        controller: _input,
                        focusNode: _focusNode,
                        enabled: canType,
                        // **Three lines at rest, not one.** The composer is
                        // where the whole session is written, and a one-line
                        // strip under a 94px stack of chrome was the owner's
                        // "message enter prompt field is very small": the
                        // glyphs got 19 of the composer's 113 logical pixels.
                        // Three lines is what a paragraph of instruction
                        // needs before it starts scrolling under itself.
                        minLines: 3,
                        maxLines: 12,
                        textInputAction: TextInputAction.newline,
                        style: theme.textTheme.bodyMedium,
                        decoration: InputDecoration(
                          isDense: true,
                          // `filled` is on in the app's theme, and with no
                          // border to bound it the fill painted a hard-edged
                          // `surfaceContainerLowest` rectangle *inside* this
                          // rounded card — a second surface behind the text,
                          // white-on-grey in light mode. The card is the
                          // surface; the field draws none of its own.
                          filled: false,
                          border: InputBorder.none,
                          // The wrapper above already spends `Insets.sm`
                          // vertically; a second helping here paid twice.
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
                      child: _toolbar(canType),
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

  /// The thumbnails, and the one line explaining where the files went.
  ///
  /// The note used to sit *below* the card and be drawn always — one
  /// `labelSmall` line plus its padding, 31 of the composer's 113 logical
  /// pixels, for a sentence that is true only when something is attached and
  /// that overflowed its row by 138px at 390 wide. It now costs nothing until
  /// there is an attachment to explain, and sits beside the thing it explains.
  Widget _attachmentStrip(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          children: [
            for (var i = 0; i < _attachments.length; i++)
              _Thumbnail(
                bytes: _attachments[i].bytes,
                onRemove: () => setState(() => _attachments.removeAt(i)),
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

  /// Attach, the session's chips, and send.
  ///
  /// Two arrangements, because at a pane's narrowest the three cannot share a
  /// row: the chips take the row to themselves and the buttons keep the one
  /// above. The threshold is named rather than inlined — it is the width the
  /// two buttons plus one chip need, and nothing else in the app branches on
  /// it (CLAUDE.md §6 forbids *scattered* raw widths, not a local measure).
  static const _toolbarRowMinWidth = 380.0;

  Widget _toolbar(bool canType) => LayoutBuilder(
    builder: (context, constraints) {
      final send = _SendButton(
        input: _input,
        attachments: _attachments,
        busy: _busy,
        onSend: canType ? _send : null,
      );
      final attach = IconButton(
        tooltip: 'Attach image (or paste with Ctrl+V)',
        onPressed: canType ? _attach : null,
        // A pointer surface's control height, the same row as the title bar's
        // buttons.
        //
        // `VisualDensity.compact` is already the app-wide default, so
        // restating it on the widget only subtracted its 8px a second time,
        // and left both of the composer's buttons **18 logical pixels tall**
        // — the primary action of the surface, two pixels off the 16x16 the
        // transcript's deliberately low-emphasis copy button measures. Note
        // that `minimumSize` alone does not fix it: `effectiveConstraints`
        // subtracts the density adjustment from the minimum, which is exactly
        // how `iconButtonTheme`'s 26 became 18. The density has to be named.
        style: IconButton.styleFrom(
          visualDensity: VisualDensity.standard,
          minimumSize: const Size.square(Chrome.control),
        ),
        icon: const Icon(AppIcons.image),
      );

      if (constraints.maxWidth > _toolbarRowMinWidth) {
        return Row(
          children: [
            attach,
            if (widget.chips.isNotEmpty)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                  child: Wrap(
                    spacing: Insets.xs,
                    runSpacing: Insets.xs,
                    children: widget.chips,
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
          if (widget.chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: widget.chips,
              ),
            ),
        ],
      );
    },
  );
}

/// Send, and the one thing in the composer that knows what has been typed.
///
/// Scoped to its own widget so that a keystroke rebuilds a 26px button rather
/// than the composer around it: the accent fill is only earned once there is
/// something to send, and that is the sole reason anything here watches the
/// controller. See `_MessageComposerState._onFocusChange`.
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
          // tree rather than a hover: without this the most important control
          // in the composer announced as "button". The chord is in the label
          // for the same reason the toolbar puts chords in tooltips — it is
          // the faster way to send, and now the only place that says so, the
          // permanent "Enter to send · Shift + Enter for new line" strip
          // under the box having been the composer's largest single spend.
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
              ? const SizedBox.square(
                  dimension: Chrome.iconSmall,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Image.memory(bytes, width: 56, height: 56, fit: BoxFit.cover),
        ),
        Positioned(
          top: -6,
          right: -6,
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
