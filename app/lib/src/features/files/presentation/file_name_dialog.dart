import 'package:flutter/material.dart';

import 'package:karmashala_files/values.dart';

/// Asks for a file or folder name — new, or a rename. The name is checked here
/// too, so a path separator is a message under the field rather than a failed
/// operation the user has to read backwards.
class FileNameDialog extends StatefulWidget {
  const FileNameDialog({
    required this.title,
    required this.action,
    this.initial = '',
    super.key,
  });

  final String title;

  /// The confirming button's words: "Create", "Rename".
  final String action;

  final String initial;

  /// The name, trimmed, or null when the user cancelled.
  static Future<String?> ask(
    BuildContext context, {
    required String title,
    required String action,
    String initial = '',
  }) => showDialog<String>(
    context: context,
    builder: (_) =>
        FileNameDialog(title: title, action: action, initial: initial),
  );

  @override
  State<FileNameDialog> createState() => _FileNameDialogState();
}

class _FileNameDialogState extends State<FileNameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  String? _refusal;

  @override
  void initState() {
    super.initState();
    _name.addListener(() {
      final refusal = _name.text.isEmpty ? null : nameRefusal(_name.text);
      if (refusal != _refusal) setState(() => _refusal = refusal);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final refusal = nameRefusal(_name.text);
    if (refusal != null) {
      setState(() => _refusal = refusal);
      return;
    }
    Navigator.of(context).pop(_name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(labelText: 'Name', errorText: _refusal),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}
