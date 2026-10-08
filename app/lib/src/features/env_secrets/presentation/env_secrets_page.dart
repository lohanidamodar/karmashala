import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../settings/presentation/copyable_name.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/env_secrets_controller.dart';
import 'env_variable_dialog.dart';

/// The environment-variables settings page: the server's vault, write-only.
/// The honesty copy is the first thing on it: "an agent can print these" must
/// be met before the first token.
class EnvSecretsPage extends ConsumerWidget {
  const EnvSecretsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(envVariablesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'ENVIRONMENT VARIABLES',
          trailing: TextButton.icon(
            onPressed: () => EnvVariableDialog.show(context),
            icon: const Icon(AppIcons.plus),
            label: const Text('Add variable'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Honesty(),
              if (names == null)
                const SettingsNote(
                  'Waiting for the Karmashala server to say which are set.',
                )
              else if (names.isEmpty)
                const SettingsNote('Nothing defined yet.')
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final variable in names)
                      _VariableCard(variable: variable),
                  ],
                ),
            ],
          ),
        ),
        SettingsSection(
          title: 'WHERE THEY GO',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Fact(
                icon: AppIcons.terminal,
                text:
                    'Terminals the server starts on its own machine get them '
                    'directly. Running panes keep the values they started '
                    'with.',
              ),
              _Fact(
                icon: AppIcons.terminalWindow,
                text:
                    'WSL panes get them via WSLENV, which shows names, not values.',
              ),
              _Fact(
                icon: AppIcons.globe,
                text:
                    'SSH gets nothing. Secrets are never sent to a remote host.',
              ),
              _Fact(
                icon: AppIcons.copySimple,
                text:
                    '"Copy command" and external terminals do not carry them.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The sentence the page exists to say, and the storage fact under it.
class _Honesty extends StatelessWidget {
  const _Honesty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    // A ruled row like the rest of the page, not a box: the warning glyph in
    // the attention tone carries the weight a filled panel used to.
    return SettingsRuled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.warning,
                size: Chrome.icon,
                color: SemanticColors.of(context).attention,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  'Any command in a terminal, yours or an agent’s, can print these.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            'Kept by the Karmashala server, in a file only its account can '
            'open, and never sent back to any window: a value can be replaced '
            'or removed, not read.',
            style: quiet,
          ),
          const SizedBox(height: Insets.xs),
          Text('Anything running as that account can read them.', style: quiet),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // One ruled row per fact, in the section's rhythm.
    return SettingsRuled(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Insets.xxs),
            child: Icon(
              icon,
              size: Chrome.icon,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// One variable the server holds: its name and when it was set. The name is
/// selectable and has a copy button; the value never reaches this page, so a
/// name is all there is to copy. Edit renames it, sets a new value, or both.
/// The buttons stay drawn and worded — this is a settings form — plus the same
/// actions on right-click, `Shift+F10` and the Menu key.
class _VariableCard extends ConsumerWidget {
  const _VariableCard({required this.variable});

  final EnvVariableName variable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return RowContextMenu(
      menuLabel: 'Actions for ${variable.name}',
      itemBuilder: () => [
        DesktopMenuItem(
          value: 'copy',
          label: 'Copy name',
          icon: AppIcons.copySimple,
        ),
        DesktopMenuItem(
          value: 'edit',
          label: 'Edit',
          icon: AppIcons.pencilSimple,
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'remove',
          label: 'Remove',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
      onSelected: (value) => switch (value) {
        'copy' => copyNameToClipboard(context, variable.name),
        'edit' => EnvVariableDialog.show(context, editing: variable.name),
        _ => _remove(context, ref),
      },
      builder: (context) => ItemCard(
        icon: AppIcons.warningCircle,
        title: CopyableName(text: variable.name, style: MonoStyles.label),
        details: [
          // The whole write-only rule, in one widget: a variable shows that
          // it is set and when, and never what it is.
          Text(
            'Set · updated ${_date(variable.updatedAt)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        actions: [
          TextButton.icon(
            onPressed: () =>
                EnvVariableDialog.show(context, editing: variable.name),
            icon: const Icon(AppIcons.pencilSimple),
            label: const Text('Edit'),
          ),
          TextButton.icon(
            onPressed: () => _remove(context, ref),
            icon: const Icon(AppIcons.trash),
            label: const Text('Remove'),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
          ),
        ],
      ),
    );
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove ${variable.name}?',
      message:
          'The value is not shown anywhere and cannot be recovered from '
          'Karmashala afterwards — you would have to paste it again.'
          '\n\nTerminals already open keep it until they are closed.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed) return;
    await ref.read(envVariablesProvider.notifier).remove(variable.name);
  }
}
