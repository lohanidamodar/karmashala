import 'package:flutter/material.dart';

/// Asks for a paired device's new name. A phone names itself at pairing, and
/// two of them once arrived calling themselves the same thing; this is the only
/// way to tell them apart again.
///
/// Its own `State`, so the field's controller lives exactly as long as the
/// dialog: disposed by the caller after `showDialog` returned, it was still
/// drawn through the route's exit animation.
class RenameDeviceDialog extends StatefulWidget {
  const RenameDeviceDialog({required this.currentName, super.key});

  final String currentName;

  /// The new name, trimmed, or null when the user cancels or leaves it empty.
  static Future<String?> show(BuildContext context, String currentName) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => RenameDeviceDialog(currentName: currentName),
    );
    final name = picked?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  @override
  State<RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<RenameDeviceDialog> {
  late final _name = TextEditingController(text: widget.currentName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename device'),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          helperText: 'Only this desktop sees it; the phone is not told.',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
