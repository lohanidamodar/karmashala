import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';

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
    super.key,
  });

  /// Sends the composed message (text + appended image paths). Awaited so the
  /// composer can show a busy state.
  final Future<void> Function(String text) onSend;
  final String hintText;
  final bool enabled;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _input = TextEditingController();
  final _attachments = <_Attachment>[];
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<Directory> _attachmentsDir() async {
    final dir = Directory(
      '${Directory.systemTemp.path}/chitragupta/attachments',
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
      final file = await openFile(
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
    final scheme = Theme.of(context).colorScheme;
    final canType = widget.enabled && !_busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        if (_attachments.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Wrap(
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
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Attach image (paste from clipboard or pick a file)',
                onPressed: canType ? _attach : null,
                icon: const Icon(AppIcons.image, size: 20),
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: canType,
                  minLines: 1,
                  maxLines: 6,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: widget.hintText,
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: canType ? _send : null,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(AppIcons.paperPlaneRight, size: 18),
              ),
            ],
          ),
        ),
        if (_attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Images are saved to a temp folder and referenced by path so the '
              'agent can read them.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
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
            iconSize: 14,
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
