import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../application/env_secrets_controller.dart';

/// Adds a variable, or replaces the value of one the server holds. **No
/// value is ever shown**: the vault is write-only, so replacing starts from an
/// empty field and there is nothing to reveal.
class EnvVariableDialog extends ConsumerStatefulWidget {
  const EnvVariableDialog({this.replacing, super.key});

  /// The name whose value is being replaced; null adds a new one.
  final String? replacing;

  static Future<void> show(BuildContext context, {String? replacing}) =>
      showDialog<void>(
        context: context,
        builder: (_) => EnvVariableDialog(replacing: replacing),
      );

  @override
  ConsumerState<EnvVariableDialog> createState() => _EnvVariableDialogState();
}

class _EnvVariableDialogState extends ConsumerState<EnvVariableDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.replacing ?? '',
  );
  final TextEditingController _value = TextEditingController();

  /// Only while typing, and only before it is saved. Once sent, a value is
  /// never rendered again by anything.
  bool _visible = false;
  String? _error;
  bool _saving = false;

  bool get _isReplace => widget.replacing != null;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text;
    final refusal = envNameRefusal(name) ?? envValueRefusal(_value.text);
    if (refusal != null) {
      setState(() => _error = refusal);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(envVariablesProvider.notifier).set(name, _value.text);
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.terminalWindow,
        title: _isReplace
            ? 'Replace ${widget.replacing}'
            : 'Add environment variable',
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
              autofocus: !_isReplace,
              enabled: !_isReplace,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'GITHUB_TOKEN',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _value,
              autofocus: _isReplace,
              obscureText: !_visible,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: _isReplace ? 'New value' : 'Value',
                suffixIcon: IconButton(
                  tooltip: _visible ? 'Hide' : 'Show',
                  icon: Icon(_visible ? AppIcons.xCircle : AppIcons.circle),
                  onPressed: () => setState(() => _visible = !_visible),
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
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
          child: Text(_isReplace ? 'Replace' : 'Add'),
        ),
      ],
    );
  }
}
