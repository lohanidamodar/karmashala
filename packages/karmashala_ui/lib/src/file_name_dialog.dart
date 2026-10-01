import 'package:flutter/material.dart';

/// Asks for a file or folder name — new, or a rename — for every browser in
/// the app. The name is checked here too, so a path separator is a message
/// under the field rather than a failed operation the user has to read
/// backwards.
class FileNameDialog extends StatefulWidget {
  const FileNameDialog({
    required this.title,
    required this.action,
    this.initial = '',
    this.label = 'Name',
    this.refuse,
    super.key,
  });

  final String title;

  /// The confirming button's words: "Create", "Rename".
  final String action;

  final String initial;

  /// The field's label.
  final String label;

  /// Why a value cannot be taken, or null when it can; [rule] when null.
  final String? Function(String value)? refuse;

  /// The server's own naming rule, installed by the app so the dialog and the
  /// server refuse the same names. Until then, the same rule spelled here.
  static String? Function(String name)? rule;

  static String? _refusal(String name) {
    final installed = rule;
    if (installed != null) return installed(name);
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'A name is needed.';
    if (trimmed == '.' || trimmed == '..') return 'That name is taken.';
    if (trimmed.contains('/') || trimmed.contains(r'\')) {
      return 'A name cannot contain a path separator.';
    }
    return null;
  }

  /// The name, trimmed, or null when the user cancelled.
  static Future<String?> ask(
    BuildContext context, {
    required String title,
    required String action,
    String initial = '',
    String label = 'Name',
    String? Function(String value)? refuse,
  }) => showDialog<String>(
    context: context,
    builder: (_) => FileNameDialog(
      title: title,
      action: action,
      initial: initial,
      label: label,
      refuse: refuse,
    ),
  );

  @override
  State<FileNameDialog> createState() => _FileNameDialogState();
}

class _FileNameDialogState extends State<FileNameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  String? _refusal;

  String? _check(String value) =>
      (widget.refuse ?? FileNameDialog._refusal)(value);

  @override
  void initState() {
    super.initState();
    _name.addListener(() {
      final refusal = _name.text.isEmpty ? null : _check(_name.text);
      if (refusal != _refusal) setState(() => _refusal = refusal);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final refusal = _check(_name.text);
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
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: _refusal,
        ),
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
