import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/env_secrets_controller.dart';
import '../domain/env_variable.dart';
import 'env_variable_dialog.dart';

/// The environment-variables settings page.
///
/// The honesty copy at the top is the feature's safety story and is deliberately
/// the first thing on the page rather than a tooltip: this app hands 50-odd MCP
/// tools to agents, one of which types into a live terminal, so "an agent can
/// print these" is a fact the user has to meet before they save their first
/// token — not one they discover afterwards.
class EnvSecretsPage extends ConsumerWidget {
  const EnvSecretsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vault = ref.watch(envSecretsControllerProvider);
    final controller = ref.read(envSecretsControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (vault.problem != null) ...[
          DesktopErrorBanner(vault.problem!),
          const SizedBox(height: Insets.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: controller.reload,
              icon: const Icon(AppIcons.arrowsClockwise),
              label: const Text('Try again'),
            ),
          ),
          const SizedBox(height: Insets.lg),
        ],
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
              _Honesty(protection: vault.protection),
              const SizedBox(height: Insets.md),
              SettingsSwitchRow(
                label: 'Load these in new terminals',
                help:
                    'Applies when a terminal opens. Panes already running keep '
                    'the values they started with.',
                value: vault.enabled,
                onChanged: controller.setEnabled,
              ),
              const SizedBox(height: Insets.sm),
              if (vault.variables.isEmpty)
                Text(
                  'Nothing defined yet. Add a variable to have every terminal '
                  'Karmashala opens — plain shells and agent panes alike — '
                  'start with it set.',
                  style: theme.textTheme.bodySmall,
                )
              else
                Column(
                  children: [
                    for (final variable in vault.variables)
                      _VariableCard(variable: variable),
                  ],
                ),
            ],
          ),
        ),
        SettingsSection(
          title: 'WHERE THEY GO',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Fact(
                icon: AppIcons.terminal,
                text:
                    'Windows shells and local terminals get them directly.',
              ),
              _Fact(
                icon: AppIcons.terminalWindow,
                text:
                    'WSL panes get them through WSLENV, which is how a Windows '
                    'variable crosses into a distribution. That means the '
                    'variable NAMES are visible inside the distro (echo '
                    '\$WSLENV); the values are not listed there.',
              ),
              _Fact(
                icon: AppIcons.globe,
                text:
                    'SSH gets nothing. Secrets are never sent to a remote host '
                    '— they would land in another machine\'s process list and '
                    'outside the protection Karmashala just applied here.',
              ),
              _Fact(
                icon: AppIcons.copySimple,
                text:
                    '"Copy command" and "Open in external terminal" do not '
                    'carry them. A command you paste elsewhere will not have '
                    'these set — assembling a secret into a clipboard string '
                    'is exactly what the stored file is protecting it from.',
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
  const _Honesty({required this.protection});

  final EnvProtection protection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(AppIcons.warning, size: Chrome.icon, color: scheme.tertiary),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  'Every terminal Karmashala opens inherits these, including '
                  'agent panes. Any command run in a terminal — by you or by '
                  'an agent — can print their values. Put here only what you '
                  'would put in a shell profile.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            protection.summary,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Anything running under your own account can read them, because '
            'Karmashala has to read them itself to start a terminal.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
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

class _VariableCard extends ConsumerWidget {
  const _VariableCard({required this.variable});

  final EnvVariable variable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  variable.secret ? AppIcons.warningCircle : AppIcons.code,
                  size: Chrome.iconTitle,
                  color: scheme.tertiary,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(variable.name, style: MonoStyles.label),
                ),
                Switch(
                  value: variable.enabled,
                  onChanged: (value) => ref
                      .read(envSecretsControllerProvider.notifier)
                      .setVariableEnabled(variable.id, value),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            // The whole write-only rule, in one widget: a secret shows that it
            // is set and when, and never what it is.
            variable.secret
                ? Text(
                    'Hidden — set, and not shown again.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : Text(
                    variable.value,
                    style: MonoStyles.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
            const SizedBox(height: Insets.xs),
            Text(
              variable.enabled
                  ? 'Updated ${_date(variable.updatedAt)}'
                  : 'Off — kept, but not loaded into terminals.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      EnvVariableDialog.show(context, existing: variable),
                  icon: const Icon(AppIcons.pencilSimple),
                  label: Text(variable.secret ? 'Replace' : 'Edit'),
                ),
                TextButton.icon(
                  onPressed: () => _remove(context, ref),
                  icon: const Icon(AppIcons.trash),
                  label: const Text('Remove'),
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                ),
              ],
            ),
          ],
        ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${variable.name}?'),
        content: Text(
          variable.secret
              ? 'The value is not shown anywhere and cannot be recovered from '
                    'Karmashala afterwards — you would have to paste it again.'
                    '\n\nTerminals already open keep it until they are closed.'
              : 'New terminals will stop getting this variable. Terminals '
                    'already open keep it until they are closed.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(envSecretsControllerProvider.notifier).remove(variable.id);
  }
}
