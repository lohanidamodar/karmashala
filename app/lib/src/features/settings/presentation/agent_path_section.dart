import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_ui/picking.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_path_repair_providers.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import '../../files/application/server_file_picking.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../environments/application/environment_values.dart'
    show EnvironmentKind;
import 'package:karmashala_session/resume.dart' show describeAge;
import 'agent_label.dart';
import 'path_field_row.dart';
import 'settings_catalog.dart';
import 'settings_section.dart';
import 'settings_theme.dart';
import 'settings_notice.dart';

/// Settings → Agents and accounts: each agent's executable, whether it still
/// opens, and a field to repoint it. "Not found" and "cannot be reached" are
/// separate states because they want opposite actions; every reading shows its
/// age.
class AgentPathSection extends ConsumerWidget {
  const AgentPathSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installations = ref.watch(agentInstallationsControllerProvider);
    if (installations.isEmpty) return const SizedBox.shrink();
    return SettingsSection(
      title: SettingsAnchor.executables.heading,
      child: AgentExecutableRows(installations: installations),
    );
  }
}

/// The path rows for [installations] — one agent's, on its card, or every
/// agent's in the standalone section — under the last check's verdict and
/// age, or the plain fact that none has run.
class AgentExecutableRows extends ConsumerWidget {
  const AgentExecutableRows({required this.installations, super.key});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repair = ref.watch(agentPathRepairProvider);
    final readings = {
      for (final reading in [...repair.repaired, ...repair.unresolved])
        reading.installation.id: reading,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsNote(
          repair.hasChecked
              // Per §19: a measurement with no timestamp is over-trusted.
              ? '${repair.summary} Checked '
                    '${describeAge(ref.watch(clockProvider).nowUtc().difference(repair.checkedAt!))}.'
              // And never a claim of health that was not observed at all.
              : 'These paths have not been checked yet this run.',
        ),
        for (final install in installations)
          AgentExecutableRow(
            installation: install,
            reading: readings[install.id],
          ),
      ],
    );
  }
}

/// One installation's path: what it is, whether it opened, and who chose it.
class AgentExecutableRow extends ConsumerStatefulWidget {
  const AgentExecutableRow({
    required this.installation,
    this.reading,
    super.key,
  });

  final AgentInstallation installation;

  /// The last reading for this row, or null when the check skipped it.
  final AgentPathReading? reading;

  @override
  ConsumerState<AgentExecutableRow> createState() => _AgentExecutableRowState();
}

class _AgentExecutableRowState extends ConsumerState<AgentExecutableRow> {
  late final TextEditingController _path = TextEditingController(
    text: widget.installation.executable.path,
  );
  String? _error;

  @override
  void didUpdateWidget(AgentExecutableRow old) {
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
  /// is spelled for *that* machine. The server runs the agent, so a server
  /// elsewhere is browsed in the installation's own environment, and only
  /// Windows is told to look for `.exe`.
  Future<void> _browse() async {
    final install = widget.installation;
    final windows =
        ref.read(capabilitiesProvider).readsServerDisk ||
        ref
            .read(environmentsControllerProvider)
            .any(
              (e) =>
                  e.id == install.environmentId &&
                  e.kind == EnvironmentKind.windowsNative,
            );
    final file = await pickServerFile(
      context,
      ref,
      what: 'an agent executable',
      environmentId: install.environmentId,
      startNear: _path.text,
      acceptedTypeGroups: windows
          ? const [
              XTypeGroup(label: 'Executables', extensions: ['exe']),
            ]
          : const [],
    );
    if (file == null) return;
    _path.text = file.path;
    await _save(file.path);
  }

  Future<void> _save(String path) async {
    final ok = await ref
        .read(agentInstallationsControllerProvider.notifier)
        .setExecutablePath(widget.installation.id, path);
    if (!mounted) return;
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

    // One ruled entry per install, like every list on the page.
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${agentLabel(ref, install.agentId)} · $environment'
                  '${version == null ? '' : ' · $version'}',
                  style: SettingsStyles.rowLabel(context),
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
          PathFieldRow(
            controller: _path,
            label: 'Executable path',
            errorText: _error,
            onSubmitted: _save,
            actions: [
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
            ],
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              // Not colour alone: the sentence says it too.
              child: SettingsNotice(
                tone: SettingsNoticeTone.danger,
                icon: AppIcons.warning,
                message: status,
              ),
            ),
        ],
      ),
    );
  }

  /// The sentence for a row that is not simply fine, or null when it is.
  static String? _status(
    AgentPathReading? reading,
  ) => switch (reading?.reachability) {
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
