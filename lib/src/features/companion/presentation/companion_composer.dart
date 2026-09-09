import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/file_picking.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';

/// The phone's message box: a prompt, and at most one file to go with it.
///
/// **The picker is only offered when the host has said what it would take.**
/// [attachments] comes straight off the session row, so the button is absent
/// for a session whose agent cannot be handed a file and the host's own
/// sentence says why — rather than the phone letting somebody pick a 4 MB
/// photo and learning after it has crossed. One file at a time: an attachment
/// means something on its own, and a queue would be a second mechanism for
/// nothing.
class CompanionComposer extends StatefulWidget {
  const CompanionComposer({
    required this.onSend,
    this.hintText = 'Send a message…',
    this.enabled = true,
    this.controller,
    this.attachments,
    this.pickFile,
    super.key,
  });

  /// Sends the prompt and whatever is attached; awaited so the box can show a
  /// busy state and keep both for retry when the host refuses.
  ///
  /// [onProgress] is handed on so the slice count can be shown: a photo is
  /// dozens of round trips over somebody's mobile data, and a silent spinner
  /// for that long is the "did that go?" this box is built against.
  final Future<void> Function(
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
  })
  onSend;

  final String hintText;
  final bool enabled;
  final TextEditingController? controller;

  /// What the host said this session would take, or null when it said nothing.
  final RemoteAttachmentSupport? attachments;

  /// The picker, so a test can stand where the platform dialog would.
  /// Production leaves it null and goes through `pickOneFile`, which announces
  /// the call to the log before it blocks the isolate.
  @visibleForTesting
  final Future<XFile?> Function(List<XTypeGroup> accepted)? pickFile;

  @override
  State<CompanionComposer> createState() => _CompanionComposerState();
}

class _CompanionComposerState extends State<CompanionComposer> {
  late TextEditingController _input;

  /// Held so the box can be focused again after a send. `TextInputAction.send`
  /// unfocuses on its way through `EditableText`, which closes the keyboard
  /// after every message — the phone's version of "did that go?".
  final _focus = FocusNode();
  bool _busy = false;

  /// The one file waiting to go, or null.
  CompanionOutgoingAttachment? _attachment;

  /// Slices acknowledged and slices in total, while an upload is in flight.
  (int, int)? _progress;

  @override
  void initState() {
    super.initState();
    _input = widget.controller ?? TextEditingController();
    _input.addListener(_onInputChange);
  }

  void _onInputChange() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CompanionComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _input.removeListener(_onInputChange);
      if (oldWidget.controller == null) {
        _input.dispose();
      }
      _input = widget.controller ?? TextEditingController();
      _input.addListener(_onInputChange);
    }
  }

  @override
  void dispose() {
    _input.removeListener(_onInputChange);
    _focus.dispose();
    if (widget.controller == null) _input.dispose();
    super.dispose();
  }

  /// What the picker offers, and what a chosen file is called on the wire.
  ///
  /// Derived from the host's list rather than from a list of our own, so a
  /// desktop that narrows what it takes narrows this without a phone release.
  static const Map<String, String> _extensionsByType = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/gif': 'gif',
    'image/webp': 'webp',
  };

  Future<void> _attach(RemoteAttachmentSupport support) async {
    final messenger = ScaffoldMessenger.of(context);
    final extensions = <String>{
      for (final type in support.mediaTypes) ?_extensionsByType[type],
      // The picker matches on extension, and a JPEG is spelled both ways.
      if (support.mediaTypes.contains('image/jpeg')) 'jpeg',
    }.toList();
    final groups = [XTypeGroup(label: 'Files', extensions: extensions)];
    final show = widget.pickFile;
    final file = show != null
        ? await show(groups)
        : await pickOneFile(
            what: 'a file to send to the desktop',
            acceptedTypeGroups: groups,
          );
    if (file == null) return;
    final name = file.name;
    final suffix = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    final mediaType = _extensionsByType.entries
        .where((e) => e.value == suffix || (e.value == 'jpg' && suffix == 'jpeg'))
        .map((e) => e.key)
        .where(support.mediaTypes.contains)
        .firstOrNull;
    if (mediaType == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'The desktop takes ${extensions.join(', ')} — not .$suffix.',
          ),
        ),
      );
      return;
    }
    final bytes = await file.readAsBytes();
    // Checked here so a file too big is refused before a byte leaves the
    // phone, on the number the host itself named.
    if (bytes.length > support.maxBytes) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'That file is ${_megabytes(bytes.length)} — the desktop takes up '
            'to ${_megabytes(support.maxBytes)}.',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _attachment = CompanionOutgoingAttachment(
        name: name,
        mediaType: mediaType,
        bytes: bytes,
      );
    });
  }

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  Future<void> _send() async {
    if (_busy || !widget.enabled) return;
    final text = _input.text.trim();
    final attachment = _attachment;
    if (text.isEmpty && attachment == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onSend(
        text,
        attachment: attachment,
        onProgress: (sent, total) {
          if (mounted) setState(() => _progress = (sent, total));
        },
      );
      if (mounted) {
        _input.clear();
        setState(() {
          _attachment = null;
          _progress = null;
        });
        // Straight into the next message, the way every other chat box
        // behaves: `TextInputAction.send` took the focus away on its way
        // through, and a keyboard that shuts itself after each turn reads as
        // the session having ended.
        _focus.requestFocus();
      }
    } catch (e) {
      // Keep the text and the file so the user can retry once the host is
      // back — an upload that failed halfway is not a file the desktop has.
      messenger.showSnackBar(
        SnackBar(content: Text(e is GatewayException ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _progress = null);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canType = widget.enabled && !_busy;
    final attachment = _attachment;
    final hasContent = _input.text.trim().isNotEmpty || attachment != null;
    final density = UiDensity.of(context);
    final support = widget.attachments;
    final progress = _progress;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        if (attachment != null)
          _AttachedRow(
            name: attachment.name,
            detail: progress == null
                ? _megabytes(attachment.bytes.length)
                // Counted slices, not a guessed percentage: this is the number
                // the host has actually acknowledged.
                : 'Sending ${progress.$1} of ${progress.$2}…',
            onRemove: canType ? () => setState(() => _attachment = null) : null,
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            density.padX,
            density.padY,
            density.padX,
            density.padY,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              // A capsule the height of the target floor, derived from it
              // rather than picked: the pill stays a capsule at one line and
              // reads as a rounded card once the text grows past it.
              borderRadius: BorderRadius.circular(Touch.target / 2),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            padding: const EdgeInsets.only(
              left: Insets.md,
              right: Insets.xs,
              top: Insets.xs,
              bottom: Insets.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (support != null && support.allowsAnything)
                  IconButton(
                    tooltip: 'Attach a file',
                    onPressed: canType && attachment == null
                        ? () => _attach(support)
                        : null,
                    constraints: BoxConstraints(
                      minWidth: density.minRow,
                      minHeight: density.minRow,
                    ),
                    icon: Icon(AppIcons.image, size: density.icon),
                  ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: canType,
                    minLines: 1,
                    maxLines: 5,
                    // The keyboard's own key has to submit, and on Android
                    // the *input type* is what decides that: an IME reads
                    // `multiline` as "this field takes newlines" and draws
                    // Return instead of the action key, so `onSubmitted` is
                    // never called and the send lands as a line break —
                    // "it only types the message but don't send".
                    // `TextField` picks that type for itself for any
                    // `maxLines != 1`, so the single-line type is named
                    // here: the box still grows to [maxLines], and Enter is
                    // Send. The desktop composer answers the same problem
                    // the other way, intercepting a hardware Enter, which
                    // is a key a soft keyboard does not deliver.
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.send,
                    focusNode: _focus,
                    onSubmitted: (_) => _send(),
                    // Named rather than inherited, because the hint has to
                    // match it: the box's default is `bodyLarge` (16) and
                    // the hint was `bodyMedium` (14), so the field's text
                    // changed size the moment anything was typed into it.
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      // `filled: true` in the app's `inputDecorationTheme`
                      // still paints with `border: InputBorder.none` — the
                      // none-border's outer path is a plain rect — so a
                      // hard-edged `surfaceContainerLowest` box was sitting
                      // inside the rounded pill. The pill is the surface.
                      filled: false,
                      isDense: true,
                      // Measured at 390x844: `EdgeInsets.zero` here made the
                      // field **24px** tall inside an 83px bar — half the
                      // touch floor, on the one control the whole screen
                      // exists for, and the "prompt field is very small"
                      // report. A 16px line plus this padding is exactly
                      // [Touch.target], so the box is a target by
                      // construction rather than by whatever the text
                      // happened to measure.
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: Insets.md,
                      ),
                      // Short enough to be one line at 16px on a 390px
                      // phone: 'Message the agent…' measures 297 against the
                      // 276 the field gets there, so it wrapped, and a
                      // two-line placeholder made the bar 24px taller than
                      // the box it was labelling. A refusal is a sentence and
                      // still wraps, which is right — that one has to be read
                      // rather than glanced at.
                      hintText: widget.hintText,
                      // No alpha on the muted grey: `onSurfaceVariant` at
                      // 70% on `surfaceContainerLow` measures about 3:1,
                      // under the 4.5:1 body-text floor, and this hint is
                      // the field's only label.
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: Touch.gap),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: canType ? _send : null,
                  style: IconButton.styleFrom(
                    backgroundColor: (canType && hasContent)
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    foregroundColor: (canType && hasContent)
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                  constraints: BoxConstraints(
                    minWidth: density.minRow,
                    minHeight: density.minRow,
                  ),
                  icon: _busy
                      ? SizedBox.square(
                          dimension: density.icon,
                          child: const CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(AppIcons.paperPlaneRight, size: density.icon),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The one file waiting to go, above the box, with a way to take it back.
///
/// A row rather than a thumbnail: the phone has already shown the user their
/// own photo in the picker, and decoding it again to draw a preview is work
/// that buys nothing the name and the size do not already say.
class _AttachedRow extends StatelessWidget {
  const _AttachedRow({
    required this.name,
    required this.detail,
    this.onRemove,
  });

  final String name;
  final String detail;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(density.padX, density.padY, Insets.xs, 0),
      child: Row(
        children: [
          // The same mark the desktop composer's own attach button carries.
          Icon(
            AppIcons.image,
            size: density.icon,
            color: scheme.onSurfaceVariant,
          ),
          SizedBox(width: Touch.gap),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          SizedBox(width: Touch.gap),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            onPressed: onRemove,
            constraints: BoxConstraints(
              minWidth: density.minRow,
              minHeight: density.minRow,
            ),
            icon: Icon(AppIcons.x, size: density.icon),
          ),
        ],
      ),
    );
  }
}
