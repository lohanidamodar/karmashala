import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/paths/path_probe.dart';
import '../../../core/util/file_picking.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_path_repair_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_path_repair.dart';
import '../../environments/application/environments_controller.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
import 'agent_label.dart';
import 'settings_section.dart';

/// Settings → Agents: where each installed agent's executable is, whether it
/// still opens, and a field to point it somewhere else.
///
/// **It reports what was measured, and says when.** Before this the app had no
/// opinion at all about a stored path: it was written once by the first scan
/// and spawned forever after. Codex self-updated, moved behind a junction chain
/// Windows refuses to traverse, and every launch failed with a
/// `ProcessException` while Settings showed a healthy-looking Codex row. §19's
/// rule applies here as much as to the Tools panel — three states, because
/// three different things need doing:
///
/// * **opens** — nothing to do;
/// * **not found** — install the CLI, or point this at it;
/// * **cannot be reached** — the file is somewhere the OS will not let this
///   app go. Installing it again will not help; a path that avoids the link
///   will.
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
                // The age of the reading, per §19: a check is a measurement,
                // and a measurement with no timestamp invites more trust than
                // it has earned.
                ? '${repair.summary} Checked '
                      '${describeAge(DateTime.now().toUtc().difference(repair.checkedAt!))}.'
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

/// One installation's path: what it is, whether it opened, who chose it, and a
/// field to change it.
class _ExecutableRow extends ConsumerStatefulWidget {
  const _ExecutableRow({required this.installation, this.reading});

  final AgentInstallation installation;

  /// The last reading for this row, when the check produced one. Null means it
  /// was not among the rows the check reported on — which for a healthy
  /// workspace is every row.
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
    // A repair moved the row under the user. Follow it, unless they are part
    // way through typing something else.
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

  /// Browse is the convenience; the field is the way out.
  ///
  /// That order is deliberate and measured: on Windows `file_selector` shows
  /// its dialog synchronously on the platform thread, which in the Flutter
  /// Windows embedder is the thread the Dart isolate runs on, so a busy
  /// isolate leaves the dialog created and never shown and the window "Not
  /// Responding". `pickOneFile` is the shared, announced entry point every
  /// Browse in this app goes through — see `core/util/file_picking.dart`, which
  /// documents the measurement and why a typed path must always work.
  Future<void> _browse() async {
    final file = await pickOneFile(
      what: 'an agent executable',
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
                  '${install.version == null ? '' : ' · ${install.version}'}',
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Which state the row is in, so it is never a mystery why a
              // repair did or did not touch it.
              Text(
                install.executableByUser ? 'set by you' : 'auto-detected',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // A field and two buttons do not fit a phone width or 150% text, so
          // the buttons drop under the field rather than overflowing it.
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
    // The distinction the whole feature exists for. "Not installed" and
    // "installed somewhere I cannot reach" imply opposite actions.
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
