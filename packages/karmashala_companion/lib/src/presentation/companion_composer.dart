import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:file_selector/file_selector.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_chrome.dart';

/// The phone's message box: a prompt, and at most one file. The picker appears
/// only when the host has said what it would take.
class CompanionComposer extends StatefulWidget {
  const CompanionComposer({
    required this.onSend,
    this.hintText = 'Send a message…',
    this.enabled = true,
    this.controller,
    this.attachments,
    this.pickFile,
    this.newRequestId,
    super.key,
  });

  /// Sends the prompt and whatever is attached; awaited so the box can show a
  /// busy state and keep both for retry when the host refuses. [onProgress]
  /// carries the slice count — a photo is dozens of round trips. [requestId]
  /// is the same value for every retry of an unchanged message.
  final Future<void> Function(
    String text, {
    CompanionOutgoingAttachment? attachment,
    void Function(int sent, int total)? onProgress,
    String? requestId,
  })
  onSend;

  /// Mints the idempotency key a send carries. Null uses a local nonce.
  final String Function()? newRequestId;

  final String hintText;
  final bool enabled;
  final TextEditingController? controller;

  /// What the host said this session would take, or null when it said nothing.
  final RemoteAttachmentSupport? attachments;

  /// The picker, so a test can stand where the platform dialog would; null in
  /// production.
  @visibleForTesting
  final Future<XFile?> Function(List<XTypeGroup> accepted)? pickFile;

  @override
  State<CompanionComposer> createState() => _CompanionComposerState();
}

class _CompanionComposerState extends State<CompanionComposer> {
  late TextEditingController _input;

  /// Held so the box can be focused again after a send: `TextInputAction.send`
  /// unfocuses inside `EditableText`, closing the keyboard after every message.
  final _focus = FocusNode();
  bool _busy = false;

  /// The one file waiting to go, or null.
  CompanionOutgoingAttachment? _attachment;

  /// Slices acknowledged and slices in total, while an upload is in flight.
  (int, int)? _progress;

  /// The key of the message in the box. Kept across a failed send so the retry
  /// is the same request to the host; dropped the moment the message changes.
  String? _sendKey;
  String _keyedText = '';
  static int _nonce = 0;

  @override
  void initState() {
    super.initState();
    _input = widget.controller ?? TextEditingController();
    _input.addListener(_onInputChange);
  }

  void _onInputChange() {
    if (_input.text != _keyedText) _sendKey = null;
    if (mounted) setState(() {});
  }

  String _mintKey() =>
      widget.newRequestId?.call() ??
      'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '-${_nonce++}';

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

  /// What the picker offers, and what a chosen file is called on the wire —
  /// intersected with the host's list, so narrowing it needs no phone release.
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
        : await _pickAttachment(groups);
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
    // Refused before a byte leaves the phone, on the host's own number.
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
      _sendKey = null;
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
    final key = _sendKey ??= _mintKey();
    _keyedText = _input.text;
    setState(() => _busy = true);
    try {
      await widget.onSend(
        text,
        attachment: attachment,
        onProgress: (sent, total) {
          if (mounted) setState(() => _progress = (sent, total));
        },
        requestId: key,
      );
      _sendKey = null;
      if (mounted) {
        _input.clear();
        setState(() {
          _attachment = null;
          _progress = null;
        });
        // `TextInputAction.send` took the focus away on its way through, and a
        // keyboard that shuts after each turn reads as the session ending.
        _focus.requestFocus();
      }
    } catch (e) {
      // Keep the text and the file for a retry: an upload that failed halfway
      // is not a file the desktop has.
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
                // Counted slices the host acknowledged, not a guessed percent.
                : 'Sending ${progress.$1} of ${progress.$2}…',
            onRemove: canType
                ? () => setState(() {
                    _attachment = null;
                    _sendKey = null;
                  })
                : null,
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
              // Derived from the target floor, so the pill stays a capsule at
              // one line and becomes a rounded card as the text grows.
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
                    // Fewer when the keyboard has left little: the box must not
                    // grow over the transcript it is replying to.
                    maxLines: companionKeyboardSqueezed(context) ? 3 : 5,
                    // Named, not inherited: `maxLines != 1` picks a multiline
                    // type, whose Android IME draws Return, not Send.
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.send,
                    focusNode: _focus,
                    onSubmitted: (_) => _send(),
                    // Named so the hint below can match it; the two defaults
                    // differ (16 vs 14) and the text resized as it was typed.
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      // The theme's `filled: true` still paints under
                      // `InputBorder.none`, whose outer path is a plain rect,
                      // putting a hard-edged box inside the rounded pill.
                      filled: false,
                      isDense: true,
                      // `EdgeInsets.zero` made the field 24px tall at 390x844;
                      // a 16px line plus this padding is exactly [Touch.target].
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: Insets.md,
                      ),
                      // Keep it one line at 16px on a 390px phone: the field
                      // gets 276px there, and a wrapped hint grows the bar.
                      hintText: widget.hintText,
                      hintMaxLines: 2,
                      // No alpha: `onSurfaceVariant` at 70% on
                      // `surfaceContainerLow` is about 3:1, under the 4.5:1
                      // floor, and this hint is the field's only label.
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
                      ? const InlineSpinner(size: InlineSpinnerSize.medium)
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

/// The one file waiting to go, above the box, with a way to take it back. A row
/// and not a thumbnail: the picker already showed the user their own photo.
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

final _log = Logger('companion.picker');

/// The phone's own picker. The desktop's `pickOneFile` first quiets terminals
/// and PTYs, which a phone does not have; this is the call and a log line.
Future<XFile?> _pickAttachment(List<XTypeGroup> accepted) async {
  _log.info('opening the file picker for a file to send to the desktop');
  try {
    return await openFile(acceptedTypeGroups: accepted);
  } on Object catch (error, stack) {
    _log.warning('the file picker was refused', error, stack);
    return null;
  }
}
