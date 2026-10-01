import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../application/env_secrets_controller.dart';

/// Adds a variable, or edits one the server holds: its name, its value, or
/// both. **No value is ever shown**: the vault is write-only, so editing
/// starts from an empty value field that keeps the current value when left
/// blank, and there is nothing to reveal.
class EnvVariableDialog extends ConsumerStatefulWidget {
  const EnvVariableDialog({this.editing, super.key});

  /// The name of the variable being edited; null adds a new one.
  final String? editing;

  static Future<void> show(BuildContext context, {String? editing}) =>
      showDialog<void>(
        context: context,
        builder: (_) => EnvVariableDialog(editing: editing),
      );

  @override
  ConsumerState<EnvVariableDialog> createState() => _EnvVariableDialogState();
}

class _EnvVariableDialogState extends ConsumerState<EnvVariableDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.editing ?? '',
  );
  final TextEditingController _value = TextEditingController();

  /// Only while typing, and only before it is saved. Once sent, a value is
  /// never rendered again by anything.
  bool _visible = false;
  String? _error;
  bool _saving = false;

  bool get _isEdit => widget.editing != null;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  /// Why the form cannot be sent as it stands, checked here before the server
  /// checks it again: the name's rules, the value's, and no clash with
  /// another variable the server holds.
  String? _refusal(String name, String value) {
    final rules =
        envNameRefusal(name) ??
        (_isEdit && value.isEmpty ? null : envValueRefusal(value));
    if (rules != null) return rules;
    final taken = [
      for (final variable
          in ref.read(envVariablesProvider) ?? const <EnvVariableName>[])
        variable.name,
    ];
    final editing = widget.editing;
    if (editing == null) {
      return taken.contains(name)
          ? '$name is already set. Use Edit on it to change it.'
          : null;
    }
    return envRenameRefusal(editing, name, taken);
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final value = _value.text;
    final editing = widget.editing;
    // Nothing changed: the current value stays, under the same name.
    if (editing != null && name == editing && value.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final refusal = _refusal(name, value);
    if (refusal != null) {
      setState(() => _error = refusal);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final vault = ref.read(envVariablesProvider.notifier);
    try {
      if (editing == null || name == editing) {
        await vault.set(name, value);
      } else {
        // One request, so the server never holds both names.
        await vault.rename(editing, name, value: value.isEmpty ? null : value);
      }
    } on DataRefused catch (refused) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = refused.message;
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _clearError(String _) {
    if (_error != null) setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.terminalWindow,
        title: _isEdit ? 'Edit ${widget.editing}' : 'Add environment variable',
        subtitle:
            'Every terminal the Karmashala server starts inherits this, '
            'including agent panes. Anything run in a terminal can print its '
            'value. Once saved, it cannot be read back — only replaced.',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'GITHUB_TOKEN',
              ),
              onChanged: _clearError,
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _value,
              obscureText: !_visible,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: _isEdit ? 'New value' : 'Value',
                // The current value is never sent back, so there is nothing
                // to fill in: blank keeps it, and a rename needs no retyping.
                helperText: _isEdit
                    ? 'Leave blank to keep the current value.'
                    : null,
                suffixIcon: IconButton(
                  tooltip: _visible ? 'Hide' : 'Show',
                  icon: Icon(_visible ? AppIcons.xCircle : AppIcons.circle),
                  onPressed: () => setState(() => _visible = !_visible),
                ),
              ),
              onChanged: _clearError,
            ),
            if (_isEdit) ...[
              const SizedBox(height: Insets.md),
              Text(
                'Terminals already open keep the old name and value until '
                'they are closed; new ones get the change.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              DesktopErrorBanner(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(_isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
