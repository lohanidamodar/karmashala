import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AcpInstallStep, DataRefused;
import 'package:karmashala_git/git.dart' show joinCommandLine, splitCommandLine;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/acp_agent_form.dart';
import '../../agents/application/acp_agent_providers.dart';
import '../../agents/application/acp_install_controller.dart';
import 'acp_custom_agent_form.dart';
import 'acp_registry_picker.dart';

/// Where the agent to add comes from.
enum AcpAgentOrigin { registry, custom }

/// **Settings → Agents → Add ACP agent…**: an agent picked from the public
/// registry, or one typed in as a command. Editing a row — a registry one
/// too, since its command may need a tweak — reopens the typed form.
class AcpAgentDialog extends ConsumerStatefulWidget {
  const AcpAgentDialog({this.existing, super.key});

  final AcpAgentRow? existing;

  static Future<void> show(BuildContext context, {AcpAgentRow? existing}) =>
      showDialog<void>(
        context: context,
        builder: (_) => AcpAgentDialog(existing: existing),
      );

  static const String protocolNote =
      'The agent must speak the Agent Client Protocol over stdio '
      '(https://agentclientprotocol.com). Karmashala runs it as a session '
      'with no terminal.';

  @override
  ConsumerState<AcpAgentDialog> createState() => _AcpAgentDialogState();
}

class _AcpAgentDialogState extends ConsumerState<AcpAgentDialog> {
  late AcpAgentOrigin _origin = widget.existing == null
      ? AcpAgentOrigin.registry
      : AcpAgentOrigin.custom;
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _command = TextEditingController(
    text: widget.existing?.command ?? '',
  );
  late final _args = TextEditingController(
    text: joinCommandLine(widget.existing?.args ?? const []),
  );
  late final _env = TextEditingController(
    text: formatEnvironmentLines(widget.existing?.env ?? const {}),
  );
  late final _modes = TextEditingController(
    text: formatAcpModeRungLines(widget.existing?.modeRungs ?? const {}),
  );
  AcpRegistryEntry? _picked;
  String? _refusal;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _env.dispose();
    _modes.dispose();
    super.dispose();
  }

  bool get _canSave => switch (_origin) {
    AcpAgentOrigin.registry => _picked != null,
    AcpAgentOrigin.custom => true,
  };

  /// Whether [entry] has no launch for this machine and is installed first.
  bool _installsFirst(AcpRegistryEntry entry) {
    final platform = ref.read(acpRegistryPlatformProvider);
    return entry.launch == null &&
        acpInstallableBinary(entry, platform) != null;
  }

  /// The step of an install this dialog started, while it runs.
  AcpInstallStep? get _installStep {
    final id = _picked?.id;
    if (!_saving || id == null) return null;
    return ref.watch(acpInstallControllerProvider).stepHere(id);
  }

  Future<void> _save() async {
    final existing = widget.existing;
    // Read before any await: an install outlives a dialog closed under it,
    // and the agent it installed is still kept.
    final installer = ref.read(acpInstallControllerProvider.notifier);
    final setup = ref.read(acpAgentsSetupProvider.notifier);
    final String name;
    final String command;
    final List<String> args;
    final Map<String, String> env;
    final AcpAgentSource source;
    final String? registryId;
    final String? iconUrl;
    Map<String, PermissionRisk>? modeRungs;
    switch (_origin) {
      case AcpAgentOrigin.registry:
        final entry = _picked;
        if (entry == null) return;
        final platform = ref.read(acpRegistryPlatformProvider);
        final launch = entry.launch;
        final binary = acpInstallableBinary(entry, platform);
        if (launch == null && binary == null) return;
        name = entry.label;
        source = AcpAgentSource.registry;
        registryId = entry.id;
        iconUrl = entry.icon;
        if (launch != null) {
          command = launch.command;
          args = launch.args;
          env = const {};
        } else {
          // Shipped as an archive alone: installed on this machine first, and
          // the row then names the executable where it landed.
          setState(() {
            _saving = true;
            _refusal = null;
          });
          try {
            command = await installer.installHere(entry.id!);
          } on Object catch (e) {
            if (mounted) {
              setState(() {
                _refusal = e is DataRefused
                    ? e.message
                    : 'Could not install ${entry.label}: $e';
                _saving = false;
              });
            }
            return;
          }
          args = binary!.args;
          env = binary.env;
        }
      case AcpAgentOrigin.custom:
        final refusal = acpAgentFormRefusal(
          name: _name.text,
          command: _command.text,
          environment: _env.text,
          modes: _modes.text,
        );
        if (refusal != null) {
          setState(() => _refusal = refusal);
          return;
        }
        name = _name.text.trim();
        command = _command.text.trim();
        args = splitCommandLine(_args.text);
        env = parseEnvironmentLines(_env.text).env;
        modeRungs = parseAcpModeRungLines(_modes.text).rungs;
        source = existing?.source ?? AcpAgentSource.custom;
        registryId = existing?.registryId;
        iconUrl = existing?.iconUrl;
    }
    if (mounted) {
      setState(() {
        _saving = true;
        _refusal = null;
      });
    }
    try {
      await setup.save(
        id: existing?.id,
        name: name,
        command: command,
        args: args,
        env: env,
        source: source,
        registryId: registryId,
        iconUrl: iconUrl,
        modeRungs: modeRungs,
      );
      if (mounted) Navigator.of(context).pop();
    } on DataRefused catch (e) {
      if (mounted) {
        setState(() {
          _refusal = e.message;
          _saving = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _refusal = 'Could not save the agent: $e';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existing = widget.existing;
    final refusal = _refusal;
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.robot,
        title: existing == null ? 'Add ACP agent' : 'Edit ${existing.name}',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_editing)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SegmentedButton<AcpAgentOrigin>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: AcpAgentOrigin.registry,
                        label: Text('From registry'),
                      ),
                      ButtonSegment(
                        value: AcpAgentOrigin.custom,
                        label: Text('Custom'),
                      ),
                    ],
                    selected: {_origin},
                    onSelectionChanged: (picked) => setState(() {
                      _origin = picked.first;
                      _refusal = null;
                    }),
                  ),
                ),
              ),
            if (refusal != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: DesktopErrorBanner(refusal),
              ),
            switch (_origin) {
              AcpAgentOrigin.registry => AcpRegistryPicker(
                picked: _picked,
                onPick: (entry) => setState(() => _picked = entry),
              ),
              AcpAgentOrigin.custom => AcpCustomAgentForm(
                name: _name,
                command: _command,
                args: _args,
                env: _env,
                modes: _modes,
                onSubmit: _save,
              ),
            },
            const SizedBox(height: Insets.md),
            if (_installStep case final step?)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: Row(
                  children: [
                    const InlineSpinner(),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        '${describeAcpInstallStep(step)} ${_picked?.label ?? ''} '
                        'installs on this machine, into its karmashala/acp '
                        'folder.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            Text(AcpAgentDialog.protocolNote, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSave && !_saving ? _save : null,
          child: Text(
            _editing
                ? 'Save'
                : _picked != null && _installsFirst(_picked!)
                ? 'Install and add'
                : 'Add',
          ),
        ),
      ],
    );
  }
}
