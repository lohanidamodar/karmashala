import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/file_picking.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_path_repair_providers.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'agent_label.dart';
import 'settings_section.dart';

/// Settings → Agents: each agent's executable, whether it still opens, and a
/// field to repoint it. "Not found" and "cannot be reached" are separate
/// states because they want opposite actions; every reading shows its age.
class AgentPathSection extends ConsumerWidget {
  const AgentPathSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final installations = ref.watch(agentInstallationsControllerProvider);
    final repair = ref.watch(agentPathRepairProvider);
    if (installations.isEmpty) return const SizedBox.shrink();

    final readings = {
      for (final reading in [...repair.repaired, ...repair.unresolved])
        reading.installation.id: reading,
    };

    return SettingsSection(
      title: 'EXECUTABLES',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            repair.hasChecked
                // Per §19: a measurement with no timestamp is over-trusted.
                ? '${repair.summary} Checked '
                      '${describeAge(ref.watch(clockProvider).nowUtc().difference(repair.checkedAt!))}.'
                // And never a claim of health that was not observed at all.
                : 'These paths have not been checked yet this run.',
            style: theme.textTheme.bodySmall,
          ),
          for (final install in installations)
            _ExecutableRow(
              installation: install,
              reading: readings[install.id],
            ),
        ],
      ),
    );
  }
}

/// One installation's path: what it is, whether it opened, and who chose it.
class _ExecutableRow extends ConsumerStatefulWidget {
  const _ExecutableRow({required this.installation, this.reading});

  final AgentInstallation installation;

  /// The last reading for this row, or null when the check skipped it.
  final AgentPathReading? reading;

  @override
  ConsumerState<_ExecutableRow> createState() => _ExecutableRowState();
}

class _ExecutableRowState extends ConsumerState<_ExecutableRow> {
  late final TextEditingController _path = TextEditingController(
    text: widget.installation.executable.path,
  );
  String? _error;

  @override
  void didUpdateWidget(_ExecutableRow old) {
    super.didUpdateWidget(old);
    // A repair moved the row; follow it unless they are mid-edit.
    final stored = widget.installation.executable.path;
    if (old.installation.executable.path != stored &&
        _path.text == old.installation.executable.path) {
      _path.text = stored;
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  /// Browse is the convenience; the field is the way out — a WSL or SSH path
  /// is spelled for *that* machine, and the dialog only opens local folders.
  Future<void> _browse() async {
    final file = await pickOneFile(
      what: 'an agent executable',
      startNear: _path.text,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Executables', extensions: ['exe']),
      ],
    );
    if (file == null) return;
    _path.text = file.path;
    _save(file.path);
  }

  void _save(String path) {
    final ok = ref
        .read(agentInstallationsControllerProvider.notifier)
        .setExecutablePath(widget.installation.id, path);
    setState(() {
      _error = ok
          ? null
          : path.trim().isEmpty
          ? 'Enter a path to the agent executable.'
          : 'Another installation of this agent already uses that path.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final install = widget.installation;
    final environment = ref.watch(
      environmentLabelForIdProvider(install.environmentId),
    );
    final status = _status(widget.reading);
    // These CLIs self-update, so the number never appears without its age.
    final version = describeVersionReading(
      install,
      now: ref.watch(clockProvider).nowUtc(),
    );

    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${agentLabel(install.agentId)} · $environment'
                  '${version == null ? '' : ' · $version'}',
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Which state the row is in, so a skipped repair is no mystery.
              Text(
                install.executableByUser ? 'set by you' : 'auto-detected',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // A field and two buttons do not fit a phone width or 150% text.
          LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                controller: _path,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Executable path',
                  errorText: _error,
                ),
                onSubmitted: _save,
              );
              final buttons = [
                OutlinedButton.icon(
                  onPressed: () => _save(_path.text),
                  icon: const Icon(AppIcons.check, size: Chrome.icon),
                  label: const Text('Save'),
                ),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
                  label: const Text('Browse'),
                ),
              ];
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    field,
                    const SizedBox(height: Insets.xs),
                    Wrap(spacing: Insets.xs, children: buttons),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: Insets.sm),
                  buttons.first,
                  const SizedBox(width: Insets.xs),
                  buttons.last,
                ],
              );
            },
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Not colour alone: the sentence says it too.
                  Icon(
                    AppIcons.warning,
                    size: Chrome.icon,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: Insets.xs),
                  Expanded(
                    child: Text(
                      status,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The sentence for a row that is not simply fine, or null when it is.
  static String? _status(AgentPathReading? reading) => switch (reading
      ?.reachability) {
    // The distinction the feature exists for: opposite actions.
    ExecutableReachability.unreachable =>
      'Installed, but this path cannot be reached — it leads through a link '
          'this machine will not follow. Set the path the executable is '
          'actually at.',
    ExecutableReachability.missing =>
      'Nothing opens at this path, and detection did not find it anywhere '
          'else. Install the CLI, or set the path yourself.',
    _ => null,
  };
}
