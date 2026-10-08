import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_cli/process.dart' show formatBytes;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/menus.dart';

import '../../../app/widgets/adaptive_modal.dart';

part 'message_composer/attachment.dart';
part 'message_composer/attachment_chips.dart';
part 'message_composer/attaching.dart';
part 'message_composer/command_palette.dart';
part 'message_composer/toolbar.dart';

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

/// One entry of the composer's snippets menu: what it is called, and the text
/// it puts in the box. Plain values, so the composer knows nothing of where
/// the library lives.
class ComposerSnippet {
  const ComposerSnippet({required this.label, required this.text});

  final String label;
  final String text;
}

/// A slash command the agent accepts, offered when the box starts with "/".
class ComposerCommand {
  const ComposerCommand({
    required this.name,
    required this.description,
    this.hint,
  });

  /// Without the slash.
  final String name;
  final String description;

  /// What the agent says to type after it, when it takes input.
  final String? hint;
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
    this.commands,
    this.imagesGoAsImages,
    this.server,
    this.attaches = true,
    this.camera,
    this.droppedFiles,
    this.takeServerFiles,
    this.serverFilesWaiting,
    this.focusRequests,
    this.working = false,
    this.onStop,
    super.key,
  });

  /// Whether the agent's turn runs. While it does, the round button is Stop
  /// (■) with the box empty, and Stop stands beside Send once something is
  /// typed — Send still queues. Without [onStop] Stop is never offered.
  final bool working;

  /// Stops the running turn.
  final VoidCallback? onStop;

  /// Whether files may be attached at all: false hides Attach and ignores a
  /// pasted or keyboard-inserted image (a phone not granted `send_attachment`).
  final bool attaches;

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

  /// The agent's slash commands, read as the box's text changes: typing "/"
  /// lists them and picking one puts it in the box. Null offers none.
  final List<ComposerCommand> Function()? commands;

  /// Whether an attached image reaches the agent as an image rather than as
  /// its path, read when the chips are drawn. Null is "as its path".
  final bool Function()? imagesGoAsImages;

  /// The server the agent runs on, read when an image is pasted or attached.
  /// Null, or one on this machine, keeps today's client temp files. One
  /// elsewhere (spec decision 11) has pasted images uploaded to it, offers
  /// "This device" or its own files to attach, and is sent its own paths.
  final PickServer Function()? server;

  /// Read when attach opens at touch density; [DevicePhotos] add "Photos"
  /// (the gallery) and "Take a photo", uploaded like any device file. Null,
  /// or answering null, offers neither.
  final DevicePhotos? Function()? camera;

  /// Paths on this machine dropped onto whatever hosts the composer, each
  /// batch attached as if picked from this device.
  final Stream<List<String>>? droppedFiles;

  /// Takes the files already on the server that wait for this composer — what
  /// *Attach to chat* on an open file queued — removing them from wherever
  /// they wait. Each is attached by path with nothing uploaded, and each path
  /// is **spelled for the agent** already, so it is sent exactly as it comes.
  ///
  /// **Pulled, never pushed**: the composer calls it only when it can attach
  /// at once — attaching allowed, enabled, not busy — so a file is never taken
  /// and then refused. Until then the files stay where they wait, and they are
  /// taken when the box mounts, when [serverFilesWaiting] says more arrived,
  /// and when the box becomes able again (enabled, attaching granted, or a
  /// send finished).
  final List<String> Function()? takeServerFiles;

  /// Notifies when files arrive for [takeServerFiles] to hand over.
  final Listenable? serverFilesWaiting;

  /// Notifies when the box should take the keyboard, its cursor at the end:
  /// a message put back in it to edit.
  final Listenable? focusRequests;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

final _log = AppLogger.named('composer');

class _MessageComposerState extends State<MessageComposer>
    with _ComposerCommands, _ComposerAttaching {
  @override
  late TextEditingController _input;
  @override
  bool _busy = false;

  /// Why the last send failed, kept over the box until the next one: a
  /// snackbar alone is gone in seconds.
  String? _sendError;
  @override
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _handleKey);
  late final AppLifecycleListener _lifecycle;

  int get _uploading => _uploads.where((upload) => upload.running).length;

  /// A thumb's composer: 48dp controls, any file, uploads drawn in the chips.
  @override
  bool get _touch => UiDensity.of(context).isTouch;

  @override
  void initState() {
    super.initState();
    // No listener on [_input] or [_focusNode] here: [_SendButton] and the
    // card's border listen for themselves, so neither rebuilds the text field.
    _input = widget.controller ?? TextEditingController();
    // Rebuilds only when the palette's matches change, not per keystroke.
    _input.addListener(_matchCommands);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _drops = widget.droppedFiles?.listen(_attachDropped);
    widget.serverFilesWaiting?.addListener(_scheduleDrain);
    widget.focusRequests?.addListener(_takeFocus);
    // Files queued before this box existed — while the transcript loaded.
    _scheduleDrain();
  }

  void _takeFocus() {
    if (!mounted) return;
    _focusNode.requestFocus();
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  StreamSubscription<List<String>>? _drops;

  /// Whether a server file taken now would be attached rather than refused.
  bool get _acceptsServerFiles => widget.attaches && widget.enabled && !_busy;

  /// [_drainServerFiles] after the current task, coalesced. From `initState`
  /// and `didUpdateWidget`, which run inside a build: taking writes the
  /// queue's provider, which a build may not, and a microtask never runs
  /// inside one.
  bool _drainScheduled = false;
  void _scheduleDrain() {
    if (_drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(() {
      _drainScheduled = false;
      _drainServerFiles();
    });
  }

  /// Takes and attaches whatever server files wait, when — and only when —
  /// they would be attached; otherwise leaves them waiting for the next
  /// chance ([MessageComposer.takeServerFiles]).
  void _drainServerFiles() {
    if (!mounted || !_acceptsServerFiles) return;
    final paths = widget.takeServerFiles?.call();
    if (paths == null || paths.isEmpty) return;
    _attachServerFiles(paths);
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    for (final upload in _uploads) {
      if (upload.running) upload.backgrounded = true;
    }
  }

  @override
  void didUpdateWidget(MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _input.removeListener(_matchCommands);
      if (oldWidget.controller == null) {
        _input.dispose();
      }
      _input = widget.controller ?? TextEditingController();
      _input.addListener(_matchCommands);
    }
    if (oldWidget.droppedFiles != widget.droppedFiles) {
      unawaited(_drops?.cancel());
      _drops = widget.droppedFiles?.listen(_attachDropped);
    }
    if (oldWidget.serverFilesWaiting != widget.serverFilesWaiting) {
      oldWidget.serverFilesWaiting?.removeListener(_scheduleDrain);
      widget.serverFilesWaiting?.addListener(_scheduleDrain);
    }
    if (oldWidget.focusRequests != widget.focusRequests) {
      oldWidget.focusRequests?.removeListener(_takeFocus);
      widget.focusRequests?.addListener(_takeFocus);
    }
    // Able again, or asked of a new source: what waited is taken now.
    if ((!oldWidget.enabled && widget.enabled) ||
        (!oldWidget.attaches && widget.attaches) ||
        oldWidget.takeServerFiles != widget.takeServerFiles) {
      _scheduleDrain();
    }
  }

  @override
  void dispose() {
    unawaited(_drops?.cancel());
    widget.serverFilesWaiting?.removeListener(_scheduleDrain);
    widget.focusRequests?.removeListener(_takeFocus);
    for (final upload in _uploads) {
      upload.cancelled = true;
    }
    _lifecycle.dispose();
    _focusNode.dispose();
    _input.removeListener(_matchCommands);
    if (widget.controller == null) _input.dispose();
    super.dispose();
  }

  /// Enter sends, Shift+Enter inserts a newline, and Ctrl/Cmd+V also attaches a
  /// clipboard image when one is present (text paste still proceeds).
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_paletteOpen && _handlePaletteKey(event) == KeyEventResult.handled) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (keys.isControlPressed || keys.isMetaPressed)) {
      if (widget.attaches) _pasteImageIfAny();
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

  Future<void> _send() async {
    // A file still on its way, or one that stopped, would go missing from
    // the message.
    if (_busy || !widget.enabled || !_readyToSend) return;
    final typed = _input.text;
    final text = typed.trim();
    if (text.isEmpty && _attachments.isEmpty && _uploads.isEmpty) return;
    if (_uploads.isNotEmpty) {
      setState(() => _busy = true);
      final landed = await _uploadQueued();
      if (!mounted) return;
      setState(() => _busy = false);
      if (!landed) {
        // Not busy any more: a server file offered meanwhile is taken now.
        _scheduleDrain();
        return;
      }
    }

    final buffer = StringBuffer(text);
    void list(String heading, Iterable<_Attachment> attached) {
      if (attached.isEmpty) return;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(heading);
      for (final a in attached) {
        buffer.write('\n');
        buffer.write(a.path);
      }
    }

    list('Attached image(s):', _attachments.where((a) => a.image));
    list('Attached file(s):', _attachments.where((a) => !a.image));

    final messenger = ScaffoldMessenger.of(context);
    final touch = _touch;
    // The box is disabled while it sends, and a disabled field gives up the
    // keys — on a phone that closes the keyboard, which reads as the session
    // ending; on a desktop the next message has to be clicked into, and on
    // the Agent dashboard the board takes the keys. Whoever had them gets
    // them back, after the frame that enables it again: a disabled field
    // takes no focus.
    final hadKeys = touch || _focusNode.hasFocus;
    setState(() {
      _busy = true;
      _sendError = null;
    });
    try {
      await widget.onSend(buffer.toString());
      if (mounted) {
        // Only what went: text a note or a draft added meanwhile stays.
        final left = textLeftAfterSend(_input.text, typed);
        _input.value = TextEditingValue(
          text: left,
          selection: TextSelection.collapsed(offset: left.length),
        );
        setState(_attachments.clear);
      }
    } on Object catch (e, stack) {
      // Keep the text/attachments so the user can retry.
      final words = e is StateError ? e.message : '$e';
      _log.warning('Send failed: $words', e, stack);
      if (mounted) setState(() => _sendError = words);
      messenger.showSnackBar(SnackBar(content: Text(words)));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (hadKeys) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusNode.requestFocus();
          });
        }
        // A server file offered while the message was sending waited in its
        // queue; it lands in the now-empty box for the next message.
        _scheduleDrain();
      }
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
    final touch = _touch;

    return LayoutBuilder(
      builder: (context, box) {
        // As many lines as the pane leaves room for. The scroll view is the
        // last resort for a pane shorter than the chrome itself.
        final maxLines = composerLinesThatFit(
          box.maxHeight - _chromeHeight(box.maxWidth, textScaler, touch),
          style: theme.textTheme.bodyMedium,
          textScaler: textScaler,
        );
        final field = TextField(
          controller: _input,
          focusNode: _focusNode,
          enabled: canType,
          // **Three lines at rest, not one.** The glyphs got 19 of the
          // composer's 113 logical pixels. Fewer only when the pane has
          // no room for three. A phone starts at one: its keyboard
          // already takes half the screen from the conversation.
          minLines: touch ? 1 : math.min(3, maxLines),
          maxLines: maxLines,
          textInputAction: TextInputAction.newline,
          // Android keyboards insert images through the field, not a
          // clipboard the app can read.
          contentInsertionConfiguration: touch && widget.attaches
              ? ContentInsertionConfiguration(
                  allowedMimeTypes: _insertableImages.keys.toList(),
                  onContentInserted: _onKeyboardContent,
                )
              : null,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            // `filled` is on in the app's theme, and with no border it
            // painted a rectangle inside this card.
            filled: false,
            // Every state, not only the resting one: the theme's own
            // focused border drew a second ring inside the card's
            // (owner, 2026-10-01). The card's ring is the focus signal.
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            // The wrapper above already spends `Insets.sm` vertically;
            // a second helping here paid twice.
            contentPadding: EdgeInsets.zero,
            // Board N2: the prompt, then the keys in a dimmer voice.
            // Two texts in a wrap rather than one span, so a narrow pane
            // puts the keys on the next line instead of clipping them.
            hint: Wrap(
              children: [
                Text(widget.hintText, style: hintStyle),
                // A soft keyboard's Enter is a new line: Send sends.
                if (!touch)
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
        );
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (touch && (_attachments.isNotEmpty || _uploads.isNotEmpty))
              _TouchAttachmentList(
                attachments: _attachments,
                uploads: _uploads,
                onRemove: canType
                    ? (i) => setState(() => _attachments.removeAt(i))
                    : null,
                onCancel: _cancelUpload,
                // Queued again, not uploaded: Send uploads it.
                onRetry: (upload) => setState(
                  () => upload
                    ..failure = null
                    ..queued = true,
                ),
              )
            else if (_attachments.isNotEmpty || _uploading > 0)
              _AttachmentStrip(
                attachments: _attachments,
                uploading: _uploading,
                asImages: widget.imagesGoAsImages?.call() ?? false,
                onRemove: (i) => setState(() => _attachments.removeAt(i)),
              ),
            if (_sendError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.md,
                  Insets.sm,
                  Insets.md,
                  0,
                ),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    key: const ValueKey('composer-send-error'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              ),
            if (_paletteOpen && canType)
              _CommandPalette(
                commands: _commandMatches,
                highlighted: _commandHighlight,
                touch: touch,
                onPicked: _pickCommand,
              ),
            if (touch)
              _touchRow(field, canType: canType)
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.md,
                  vertical: Insets.sm,
                ),
                child: field,
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
                  touch: touch,
                  attaches: widget.attaches,
                  onAttach: canType ? _attachAnyFile : null,
                  snippets: snippets == null
                      ? null
                      : _SnippetsButton(
                          snippets: snippets,
                          touch: touch,
                          onPicked: canType ? _insertSnippet : null,
                        ),
                  send: _sendOrStop(canType: canType, touch: touch),
                ),
              ),
            ],
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

  /// **The phone's composer is one row**: attach and snippets, the field,
  /// send — the shape every messaging app has. Stacked, the 48dp buttons
  /// under a one-line field left a band of nothing twice its height (owner,
  /// 2026-10-01). The buttons stay at the bottom as the text grows, where the
  /// thumb already is; any chips go on a line of their own under it.
  /// Send, or Stop while the agent works: Stop alone with nothing typed, the
  /// two side by side once something is. Stop ignores [canType]: a held box
  /// must not hold the way to stop the turn.
  Widget _sendOrStop({required bool canType, required bool touch}) {
    final send = _SendButton(
      input: _input,
      attachments: _attachments,
      busy: _busy,
      touch: touch,
      queued: _uploads.isNotEmpty,
      onSend: canType && _readyToSend ? _send : null,
    );
    final onStop = widget.onStop;
    if (!widget.working || onStop == null) return send;
    return ListenableBuilder(
      listenable: _input,
      builder: (context, _) {
        final stop = _StopButton(touch: touch, onStop: onStop);
        final typed =
            _input.text.trim().isNotEmpty ||
            _attachments.isNotEmpty ||
            _uploads.isNotEmpty;
        if (!typed) return stop;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            stop,
            const SizedBox(width: Insets.xs),
            send,
          ],
        );
      },
    );
  }

  Widget _touchRow(Widget field, {required bool canType}) {
    final snippets = widget.snippets;
    final tools = widget.attaches || snippets != null;
    return Padding(
      padding: const EdgeInsets.all(Insets.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.attaches)
                _ToolbarIconButton(
                  tooltip: 'Attach a file',
                  icon: AppIcons.plus,
                  touch: true,
                  onPressed: canType ? _attachAnyFile : null,
                ),
              if (snippets != null)
                _SnippetsButton(
                  snippets: snippets,
                  touch: true,
                  onPicked: canType ? _insertSnippet : null,
                ),
              Expanded(
                // A thumb's height even for one line, the text centred in it,
                // so the row's controls line up with the words.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Touch.target),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        tools ? Insets.xs : Insets.md,
                        Insets.sm,
                        Insets.sm,
                        Insets.sm,
                      ),
                      child: field,
                    ),
                  ),
                ),
              ),
              _sendOrStop(canType: canType, touch: true),
            ],
          ),
          if (widget.chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.sm,
                Insets.xs,
                Insets.sm,
                Insets.xs,
              ),
              child: Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: widget.chips,
              ),
            ),
        ],
      ),
    );
  }

  /// Board N2's card corner: 12px, between the row radius and the dialog's.
  static const _radius = Radii.md + Insets.hair * 2;

  /// The key hint's share of the muted colour: board N2's `--dim` under
  /// `--mut`, as a fraction rather than a second grey.
  static const _dimAlpha = 0.7;

  /// Everything but the text lines, near enough to size the box by: guessing
  /// low costs a few pixels of scroll, never an overflow.
  double _chromeHeight(double width, TextScaler textScaler, bool touch) {
    final palette = _paletteOpen
        ? _CommandPalette.heightFor(_commandMatches.length, touch: touch)
        : 0.0;
    // Bottom padding, the ring, the text's own padding, the toolbar.
    // The phone's one row: its padding, the ring and the row's lines of
    // text beside the buttons — which the lines are counted into, so only
    // the chips' own line is chrome.
    if (touch) {
      var height = palette + Insets.md + 2 + 2 * Insets.xs + 2 * Insets.sm;
      if (widget.chips.isNotEmpty) height += 2 * Insets.xs + Chrome.control;
      final rows = _attachments.length + _uploads.length;
      if (rows > 0) height += Insets.sm + rows * _TouchAttachmentRow.height;
      return height;
    }
    var height =
        palette +
        Insets.md +
        2 +
        2 * Insets.sm +
        _SendButton.diameterFor(touch: touch) +
        Insets.sm;
    final toolbarWidth = width - 2 * Insets.sm - 2;
    if (widget.chips.isNotEmpty &&
        toolbarWidth <= _ComposerToolbar.rowMinWidth) {
      height += Insets.xs + Chrome.control;
    }
    if (touch) {
      final rows = _attachments.length + _uploads.length;
      if (rows > 0) height += Insets.sm + rows * _TouchAttachmentRow.height;
    } else if (_attachments.isNotEmpty || _uploading > 0) {
      height += Insets.sm + _AttachmentChip.height;
    }
    return height;
  }
}

/// What stays in a box that held [now] once [sent] — the box's text when Send
/// was pressed — has gone: anything added meanwhile, never the sent words.
String textLeftAfterSend(String now, String sent) {
  if (now == sent) return '';
  if (sent.isNotEmpty && now.startsWith(sent)) {
    return now.substring(sent.length).trimLeft();
  }
  return now;
}
