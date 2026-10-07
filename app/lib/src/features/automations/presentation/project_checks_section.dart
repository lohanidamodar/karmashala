import '../../workspaces/data/workspace_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/git.dart' show joinCommandLine, splitCommandLine;
import 'package:karmashala_git/repositories.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/automation_providers.dart';
import 'package:karmashala_automations/checks.dart';

/// The preconditions the unattended gate refuses without, on the automations'
/// own page: a refusal three screens from its fix is a setting nobody finds.
class ProjectChecksSection extends ConsumerWidget {
  const ProjectChecksSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositories = ref.watch(workspaceDataProvider).repositories;

    return SettingsSection(
      title: 'VERIFICATION AND PROJECT CHECKS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'Automations need verification on and at least one check.',
          ),
          if (repositories.isEmpty)
            const SettingsNote('No checkouts have been scanned yet.')
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

    // One ruled entry per checkout, like every list on a settings page — not
    // a bordered box.
    return SettingsCard(
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
              onPressed: () => addProjectCheck(context, ref, repository),
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
                fontFamilyFallback: kMonoFallback,
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

/// Asks for a check for [repository] and adds it; [turnOn] also turns its
/// checks on, as making an automation ready means.
Future<void> addProjectCheck(
  BuildContext context,
  WidgetRef ref,
  Repository repository, {
  bool turnOn = false,
}) async {
  final result = await showDialog<({String name, List<String> command})>(
    context: context,
    builder: (_) => _AddCheckDialog(checkoutName: repository.name),
  );
  if (result == null) return;
  final controller = ref.read(automationControllerProvider)
    ..addCheck(repository.id, result.name, result.command);
  if (turnOn) controller.setVerificationEnabled(repository.id, enabled: true);
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
      title: DesktopDialogTitle(
        icon: AppIcons.listChecks,
        title: 'A check for ${widget.checkoutName}',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
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
