import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../application/env_secrets_controller.dart';
import '../data/env_vault.dart';
import '../domain/env_variable.dart';

/// Adds a variable, or edits one that exists. **A secret's value is never
/// shown**: editing offers to replace it, and there is no reveal.
class EnvVariableDialog extends ConsumerStatefulWidget {
  const EnvVariableDialog({this.existing, super.key});

  final EnvVariable? existing;

  static Future<void> show(BuildContext context, {EnvVariable? existing}) =>
      showDialog<void>(
        context: context,
        builder: (_) => EnvVariableDialog(existing: existing),
      );

  @override
  ConsumerState<EnvVariableDialog> createState() => _EnvVariableDialogState();
}

class _EnvVariableDialogState extends ConsumerState<EnvVariableDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _value = TextEditingController(
    // A plain variable's value is shown and editable; a secret's is not shown
    // at all, so the field starts empty and means "replace".
    text: widget.existing != null && !widget.existing!.secret
        ? widget.existing!.value
        : '',
  );
  late bool _secret = widget.existing?.secret ?? true;

  /// Only while typing, and only before it is saved. Once stored, a secret is
  /// never rendered again by anything.
  bool _visible = false;
  String? _error;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  /// True when editing a secret and the value field was left empty — keep what
  /// is stored.
  bool get _keepsExistingValue =>
      _isEdit && widget.existing!.secret && _value.text.isEmpty;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text;
    final refusal =
        envNameRefusal(name) ??
        (_keepsExistingValue ? null : envValueRefusal(_value.text));
    if (refusal != null) {
      setState(() => _error = refusal);
      return;
    }
    final vault = ref.read(envSecretsControllerProvider);
    if (_secret && !vault.canStoreSecrets) {
      setState(
        () => _error =
            'Karmashala could not restrict the environment variables folder '
            'to your account, so it will not store a secret there. This '
            'variable can still be saved if you untick "Hide this value".',
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final controller = ref.read(envSecretsControllerProvider.notifier);
    try {
      if (_isEdit) {
        await controller.update(
          widget.existing!.id,
          name: name,
          value: _keepsExistingValue ? null : _value.text,
          secret: _secret,
        );
      } else {
        await controller.add(
          name: name,
          value: _value.text,
          secret: _secret,
        );
      }
    } on EnvVaultRefusal catch (refusal) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = refusal.message;
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.terminalWindow,
        title: _isEdit ? 'Edit variable' : 'Add environment variable',
        subtitle:
            'Every terminal Karmashala opens inherits this, including agent '
            'panes. Anything run in a terminal can print its value.',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: !_isEdit,
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
              autofocus: _isEdit,
              obscureText: _secret && !_visible,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: _keepsExistingValue
                    ? 'New value (leave empty to keep the current one)'
                    : 'Value',
                suffixIcon: _secret
                    ? IconButton(
                        tooltip: _visible ? 'Hide' : 'Show',
                        icon: Icon(
                          _visible ? AppIcons.xCircle : AppIcons.circle,
                        ),
                        onPressed: () => setState(() => _visible = !_visible),
                      )
                    : null,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: Insets.sm),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _secret,
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      _secret = value ?? false;
                      if (!_secret) _visible = true;
                    }),
              title: const Text('Hide this value'),
              subtitle: Text(
                _secret
                    ? 'Karmashala will not show it again after you save. It is '
                          'kept out of the log, and can be replaced but not read '
                          'back.'
                    : 'The value stays visible in this list — for things like '
                          'EDITOR that are not secret.',
                style: theme.textTheme.bodySmall,
              ),
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
          child: Text(_isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
