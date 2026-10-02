import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_git/git.dart' show joinCommandLine, splitCommandLine;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/acp_agent_form.dart';
import '../../agents/application/acp_agent_providers.dart';

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
    super.dispose();
  }

  bool get _canSave => switch (_origin) {
    AcpAgentOrigin.registry => _picked != null,
    AcpAgentOrigin.custom => true,
  };

  Future<void> _save() async {
    final existing = widget.existing;
    final String name;
    final String command;
    final List<String> args;
    final Map<String, String> env;
    final AcpAgentSource source;
    final String? registryId;
    final String? iconUrl;
    switch (_origin) {
      case AcpAgentOrigin.registry:
        final entry = _picked;
        final launch = entry?.launchFor(ref.read(acpRegistryPlatformProvider));
        if (entry == null || launch == null) return;
        name = entry.label;
        command = launch.command;
        args = launch.args;
        env = const {};
        source = AcpAgentSource.registry;
        registryId = entry.id;
        iconUrl = entry.icon;
      case AcpAgentOrigin.custom:
        final refusal = acpAgentFormRefusal(
          name: _name.text,
          command: _command.text,
          environment: _env.text,
        );
        if (refusal != null) {
          setState(() => _refusal = refusal);
          return;
        }
        name = _name.text.trim();
        command = _command.text.trim();
        args = splitCommandLine(_args.text);
        env = parseEnvironmentLines(_env.text).env;
        source = existing?.source ?? AcpAgentSource.custom;
        registryId = existing?.registryId;
        iconUrl = existing?.iconUrl;
    }
    setState(() {
      _saving = true;
      _refusal = null;
    });
    try {
      await ref
          .read(acpAgentsSetupProvider.notifier)
          .save(
            id: existing?.id,
            name: name,
            command: command,
            args: args,
            env: env,
            source: source,
            registryId: registryId,
            iconUrl: iconUrl,
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
              AcpAgentOrigin.registry => _RegistryPicker(
                picked: _picked,
                onPick: (entry) => setState(() => _picked = entry),
              ),
              AcpAgentOrigin.custom => _CustomForm(
                name: _name,
                command: _command,
                args: _args,
                env: _env,
                onSubmit: _save,
              ),
            },
            const SizedBox(height: Insets.md),
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
          child: Text(_editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

/// The registry's agents, filterable, each with the launch this machine would
/// use; one with no build for it is listed but cannot be picked.
class _RegistryPicker extends ConsumerStatefulWidget {
  const _RegistryPicker({required this.picked, required this.onPick});

  final AcpRegistryEntry? picked;
  final ValueChanged<AcpRegistryEntry> onPick;

  @override
  ConsumerState<_RegistryPicker> createState() => _RegistryPickerState();
}

class _RegistryPickerState extends ConsumerState<_RegistryPicker> {
  final _filter = TextEditingController();

  /// Rows shown before the list scrolls, in row heights.
  static const double _listHeight = 5 * Chrome.menuRowTall;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = ref.watch(acpRegistryCatalogProvider);
    final platform = ref.watch(acpRegistryPlatformProvider);
    // By field, not by state: a value or an error is shown whatever else the
    // provider is doing.
    if (catalog.value case final value?) return _list(theme, value, platform);
    if (catalog.error case final error?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesktopErrorBanner(
            'The registry could not be fetched: $error. '
            'A custom agent can still be added.',
          ),
          const SizedBox(height: Insets.xs),
          // The fetch is one per dialog; this asks again without closing it.
          TextButton.icon(
            onPressed: () => ref.invalidate(acpRegistryCatalogProvider),
            icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
            label: const Text('Fetch again'),
          ),
        ],
      );
    }
    return Row(
      children: [
        const InlineSpinner(),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            'Fetching the registry…',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _list(ThemeData theme, AcpRegistryCatalog catalog, String platform) {
    if (catalog.agents.isEmpty) {
      return Text(
        'The registry lists no agents.',
        style: theme.textTheme.bodySmall,
      );
    }
    final query = _filter.text.trim().toLowerCase();
    final shown = [
      for (final entry in catalog.agents)
        if (query.isEmpty ||
            entry.label.toLowerCase().contains(query) ||
            (entry.description?.toLowerCase().contains(query) ?? false))
          entry,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _filter,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
                  hintText: 'Filter agents',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            IconButton(
              tooltip: 'Fetch the registry again',
              icon: const Icon(
                AppIcons.arrowsClockwise,
                size: Chrome.iconAction,
              ),
              onPressed: () => ref.invalidate(acpRegistryCatalogProvider),
            ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        SizedBox(
          height: _listHeight,
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    'No agent matches.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  primary: false,
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final entry = shown[index];
                    final launch = entry.launchFor(platform);
                    final detail = [
                      ?entry.version,
                      launch == null
                          ? 'no build for this machine'
                          : [launch.command, ...launch.args].join(' '),
                    ].join(' · ');
                    return ListTile(
                      key: ValueKey('acp-registry-${entry.id ?? index}'),
                      dense: true,
                      enabled: launch != null,
                      selected: identical(entry, widget.picked),
                      selectedTileColor: theme.colorScheme.primaryContainer
                          .withValues(alpha: 0.4),
                      title: Text(
                        entry.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: MonoStyles.small.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: launch == null ? null : () => widget.onPick(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Name, command, arguments and environment, typed.
class _CustomForm extends StatelessWidget {
  const _CustomForm({
    required this.name,
    required this.command,
    required this.args,
    required this.env,
    required this.onSubmit,
  });

  final TextEditingController name;
  final TextEditingController command;
  final TextEditingController args;
  final TextEditingController env;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: theme.textTheme.bodyMedium?.fontSize,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Name',
            hintText: 'My agent',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: command,
          style: mono,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Command',
            hintText: 'An executable on PATH, or its full path',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: args,
          style: mono,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Arguments',
            hintText: '--acp  (quotes keep words together)',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: env,
          style: mono,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Environment',
            hintText: 'KEY=value, one per line',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }
}
