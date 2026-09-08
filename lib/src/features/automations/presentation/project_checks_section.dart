import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../git/domain/worktree_setup.dart'
    show joinCommandLine, splitCommandLine;
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/automation_providers.dart';
import '../domain/project_check.dart';

/// The preconditions the unattended gate refuses without.
///
/// **On the same page as the automations, deliberately.** Every refusal a
/// person meets when arming one points at this section, and a setting whose
/// refusal is three screens away from its fix is a setting nobody finds.
class ProjectChecksSection extends ConsumerWidget {
  const ProjectChecksSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repositories = ref.watch(repositoryDaoProvider).getAll();

    return SettingsSection(
      title: 'VERIFICATION AND PROJECT CHECKS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Nobody is watching an automation run, so what it did has to be '
            'checkable without you. A checkout with verification off, or with '
            'no check at all, cannot have an automation armed in it — this is '
            'the single rule that makes running an agent while you are away '
            'defensible.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'A check is the command you would run to see whether the work '
            'still stands. It is stored as arguments, split once, here — so no '
            'second parser gets between what you typed and the shell that '
            'reads it.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.md),
          if (repositories.isEmpty)
            Text(
              'No checkouts have been scanned yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final repository in repositories)
              _CheckoutChecks(
                key: ValueKey(repository.id),
                repository: repository,
              ),
        ],
      ),
    );
  }
}

class _CheckoutChecks extends ConsumerWidget {
  const _CheckoutChecks({required this.repository, super.key});

  final Repository repository;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = ref.watch(
      projectVerificationEnabledProvider(repository.id),
    );
    final checks = ref.watch(projectChecksProvider(repository.id));

    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  repository.name,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Semantics(
                label: 'Verify ${repository.name}',
                child: Switch(
                  value: enabled,
                  onChanged: (value) => ref
                      .read(automationControllerProvider)
                      .setVerificationEnabled(repository.id, enabled: value),
                ),
              ),
            ],
          ),
          if (checks.isEmpty)
            Text(
              'No check yet. An automation cannot be armed here until there '
              'is one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else
            for (final check in checks)
              _CheckLine(key: ValueKey(check.id), check: check),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _addCheck(context, ref, repository),
              child: const Text('Add a check'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckLine extends ConsumerWidget {
  const _CheckLine({required this.check, super.key});

  final ProjectCheck check;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(check.name, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              joinCommandLine(check.command),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: kMonoFamily,
                color: theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Remove ${check.name}',
            icon: const Icon(AppIcons.x),
            onPressed: () =>
                ref.read(automationControllerProvider).removeCheck(check.id),
          ),
        ],
      ),
    );
  }
}

Future<void> _addCheck(
  BuildContext context,
  WidgetRef ref,
  Repository repository,
) async {
  final result = await showDialog<({String name, List<String> command})>(
    context: context,
    builder: (_) => _AddCheckDialog(checkoutName: repository.name),
  );
  if (result == null) return;
  ref
      .read(automationControllerProvider)
      .addCheck(repository.id, result.name, result.command);
}

class _AddCheckDialog extends StatefulWidget {
  const _AddCheckDialog({required this.checkoutName});

  final String checkoutName;

  @override
  State<_AddCheckDialog> createState() => _AddCheckDialogState();
}

class _AddCheckDialogState extends State<_AddCheckDialog> {
  final _name = TextEditingController();
  final _command = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final command = splitCommandLine(_command.text);
    final refusal =
        projectCheckNameRefusal(_name.text) ??
        projectCheckCommandRefusal(command);
    return AlertDialog(
      title: Text('A check for ${widget.checkoutName}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'the test suite',
              ),
            ),
            const SizedBox(height: Insets.sm),
            TextField(
              controller: _command,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Command',
                hintText: 'flutter test',
              ),
            ),
            if (command.isNotEmpty) ...[
              const SizedBox(height: Insets.xs),
              // What is stored, shown back before it is stored: the split runs
              // once, and this is its result.
              Text(
                'Stored as ${command.length} argument'
                '${command.length == 1 ? '' : 's'}: '
                '${command.map((a) => '"$a"').join(' ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (refusal != null) ...[
              const SizedBox(height: Insets.xs),
              Text(
                refusal,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: refusal != null
              ? null
              : () => Navigator.of(
                  context,
                ).pop((name: _name.text.trim(), command: command)),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
