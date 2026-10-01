import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/checkout_picker.dart';
import '../application/run_configurations.dart';
import '../data/flutter_data.dart';

/// Run the selected checkout under one of its project's run configurations,
/// on the server, in a session every window shows. Nothing when no checkout
/// is selected: there is nothing to run.
class FlutterRunBar extends ConsumerStatefulWidget {
  const FlutterRunBar({super.key});

  @override
  ConsumerState<FlutterRunBar> createState() => _FlutterRunBarState();
}

class _FlutterRunBarState extends ConsumerState<FlutterRunBar> {
  final _device = TextEditingController();
  String? _chosenId;
  bool _busy = false;

  @override
  void dispose() {
    _device.dispose();
    super.dispose();
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  void _choose(FlutterRunConfiguration? configuration) => setState(() {
    _chosenId = configuration?.id;
    _device.text = configuration?.deviceId ?? _device.text;
  });

  Future<void> _run(
    Repository checkout,
    FlutterRunConfiguration? chosen,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final device = _device.text.trim();
      _say(
        await ref
            .read(flutterDataProvider)
            .runStart(
              checkout.id,
              configurationId: chosen?.id,
              deviceId: device.isEmpty ? null : device,
            ),
      );
    } on DataRefused catch (refused) {
      _say(refused.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(
    Repository checkout,
    FlutterRunConfiguration? existing,
  ) async {
    final saved = await showDialog<_Edited>(
      context: context,
      builder: (_) => _RunConfigurationDialog(
        projectId: checkout.projectId,
        existing: existing,
      ),
    );
    if (saved == null) return;
    ref.invalidate(flutterRunConfigsProvider(checkout.projectId));
    if (mounted) _choose(saved.configuration);
  }

  @override
  Widget build(BuildContext context) {
    final checkout = ref.watch(selectedCheckoutProvider);
    if (checkout == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final configurations =
        ref
            .watch(flutterRunConfigsProvider(checkout.projectId))
            .asData
            ?.value ??
        const <FlutterRunConfiguration>[];
    final chosen = configurations.where((c) => c.id == _chosenId).firstOrNull;

    final bar = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xs,
        vertical: Insets.xs,
      ),
      child: Wrap(
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PopupMenuButton<Object>(
            tooltip: chosen?.describe() ?? 'Run without a configuration',
            onSelected: (picked) => switch (picked) {
              final FlutterRunConfiguration configuration => _choose(
                configuration,
              ),
              #none => _choose(null),
              #edit => _edit(checkout, chosen),
              _ => _edit(checkout, null),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: #none,
                child: Text('No configuration'),
              ),
              for (final configuration in configurations)
                PopupMenuItem(
                  value: configuration,
                  child: Text(configuration.name),
                ),
              const PopupMenuDivider(),
              if (chosen != null)
                PopupMenuItem(
                  value: #edit,
                  child: Text('Edit ${chosen.name}…'),
                ),
              const PopupMenuItem(
                value: #create,
                child: Text('New configuration…'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    chosen?.name ?? 'No configuration',
                    style: theme.textTheme.labelSmall,
                  ),
                  const Icon(AppIcons.caretDown, size: Chrome.iconAction),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: TextField(
              controller: _device,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Device id',
              ),
            ),
          ),
          Tooltip(
            message:
                'flutter run on the Karmashala server for ${checkout.name}, '
                'in a session every window shows',
            child: TextButton.icon(
              onPressed: _busy ? null : () => _run(checkout, chosen),
              icon: const Icon(AppIcons.play, size: Chrome.iconAction),
              label: const Text('Run'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall,
              ),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [bar, const Divider(height: 1)],
    );
  }
}

/// What the editor left behind: the saved configuration, or null for one it
/// deleted.
class _Edited {
  const _Edited(this.configuration);

  final FlutterRunConfiguration? configuration;
}

class _RunConfigurationDialog extends ConsumerStatefulWidget {
  const _RunConfigurationDialog({required this.projectId, this.existing});

  final String projectId;
  final FlutterRunConfiguration? existing;

  @override
  ConsumerState<_RunConfigurationDialog> createState() =>
      _RunConfigurationDialogState();
}

class _RunConfigurationDialogState
    extends ConsumerState<_RunConfigurationDialog> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _directory = TextEditingController(
    text: widget.existing?.projectDirectory,
  );
  late final _target = TextEditingController(text: widget.existing?.target);
  late final _flavor = TextEditingController(text: widget.existing?.flavor);
  late final _defines = TextEditingController(
    text: widget.existing?.dartDefines.join('\n'),
  );
  late final _files = TextEditingController(
    text: widget.existing?.dartDefineFiles.join('\n'),
  );
  late final _device = TextEditingController(text: widget.existing?.deviceId);
  late var _mode = widget.existing?.buildMode ?? FlutterBuildMode.debug;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _directory,
      _target,
      _flavor,
      _defines,
      _files,
      _device,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  static String? _text(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  static List<String> _lines(TextEditingController controller) => [
    for (final line in controller.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  Future<void> _act(Future<_Edited> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final edited = await action();
      if (mounted) Navigator.of(context).pop(edited);
    } on DataRefused catch (refused) {
      if (mounted) setState(() => _error = refused.message);
    } on FlutterRunConfigurationInvalid catch (invalid) {
      if (mounted) setState(() => _error = invalid.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_Edited> _save() async {
    final draft = FlutterRunConfiguration(
      id: widget.existing?.id ?? '',
      projectId: widget.projectId,
      name: _name.text.trim(),
      projectDirectory: _text(_directory),
      target: _text(_target),
      flavor: _text(_flavor),
      buildMode: _mode,
      dartDefines: _lines(_defines),
      dartDefineFiles: _lines(_files),
      deviceId: _text(_device),
    )..validate();
    return _Edited(await ref.read(flutterDataProvider).saveRunConfig(draft));
  }

  Future<void> _confirmDelete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${widget.existing!.name}?'),
        content: const Text(
          'Every checkout of this project loses it, agents included.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure == true) await _act(_delete);
  }

  Future<_Edited> _delete() async {
    await ref.read(flutterDataProvider).deleteRunConfig(widget.existing!.id);
    return const _Edited(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget field(
      TextEditingController controller,
      String label, {
      String? hint,
      bool lines = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: TextField(
        controller: controller,
        enabled: !_busy,
        minLines: lines ? 2 : 1,
        maxLines: lines ? 5 : 1,
        style: theme.textTheme.bodySmall,
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
        ),
      ),
    );

    return AlertDialog(
      title: Text(
        widget.existing == null
            ? 'New run configuration'
            : 'Edit ${widget.existing!.name}',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field(_name, 'Name', hint: 'dev'),
              field(_target, 'Entrypoint', hint: 'lib/main_dev.dart'),
              field(_flavor, 'Flavor', hint: 'dev'),
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: DropdownButtonFormField<FlutterBuildMode>(
                  initialValue: _mode,
                  isDense: true,
                  decoration: const InputDecoration(labelText: 'Build mode'),
                  items: [
                    for (final mode in FlutterBuildMode.values)
                      DropdownMenuItem(value: mode, child: Text(mode.name)),
                  ],
                  onChanged: _busy
                      ? null
                      : (mode) => setState(() => _mode = mode ?? _mode),
                ),
              ),
              field(
                _defines,
                '--dart-define',
                hint: 'API_URL=https://staging.example.com, one per line',
                lines: true,
              ),
              field(
                _files,
                '--dart-define-from-file',
                hint: 'env/dev.json, one per line',
                lines: true,
              ),
              field(_device, 'Default device', hint: 'emulator-5554, chrome'),
              field(_directory, 'Sub-project', hint: 'app'),
              Text(
                'Defines are kept in Karmashala\'s database in plain text: put '
                'secrets in a define file instead.',
                style: theme.textTheme.labelSmall,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.sm),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            onPressed: _busy ? null : _confirmDelete,
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _act(_save),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
