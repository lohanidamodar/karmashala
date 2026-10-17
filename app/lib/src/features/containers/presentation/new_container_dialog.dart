import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/container_creations_controller.dart';

/// The memory sizes offered, in MB.
const _memoryChoices = [1024, 2048, 4096, 8192, 16384];

/// What a host check found, in one line: `Docker 27.3.1 · x86_64 · 8 cores ·
/// 11.2 GB free · 74 GB disk`.
String describeHostCheck(HostCheck check) => [
  if (check.dockerVersion != null) 'Docker ${check.dockerVersion}',
  ?check.architecture,
  if (check.cores != null) '${check.cores} cores',
  if (check.freeMemoryMb != null) '${formatMemory(check.freeMemoryMb!)} free',
  if (check.freeDiskMb != null) '${formatMemory(check.freeDiskMb!)} disk',
].join(' · ');

/// "New Linux container": a name, the host it runs on (each with what its
/// check found, and why not when it cannot), the distribution, CPUs and
/// memory, and the agent CLIs it comes with. Create hands it to the server
/// and closes; the Containers list shows the progress.
class NewContainerDialog extends ConsumerStatefulWidget {
  const NewContainerDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const NewContainerDialog(),
  );

  @override
  ConsumerState<NewContainerDialog> createState() => _NewContainerDialogState();
}

class _NewContainerDialogState extends ConsumerState<NewContainerDialog> {
  final _name = TextEditingController();
  String? _hostId;
  ContainerDistro _distro = ContainerDistro.ubuntu2404;
  int _cpus = 2;
  int _memoryMb = 4096;
  final _agents = <ContainerAgentCli>{
    ContainerAgentCli.claude,
    ContainerAgentCli.codex,
  };
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create(ContainerHostChoice host, HostCheck? check) {
    final spec = ContainerSpec(
      name: _name.text.trim(),
      distro: _distro,
      cpus: _cpus,
      memoryMb: _memoryMb,
      agents: [
        for (final cli in ContainerAgentCli.values)
          if (_agents.contains(cli)) cli,
      ],
    );
    final taken = ref
        .read(containerMachinesProvider)
        .any((machine) => machine.name == spec.name);
    final problem = taken
        ? 'A machine is already called ${spec.name}.'
        : containerSpecProblem(
            spec,
            cores: check?.cores,
            freeMemoryMb: check?.freeMemoryMb,
          );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    ref.read(containerCreationsControllerProvider.notifier).start(host, spec);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hosts = ref.watch(containerHostsProvider);
    final chosen = hosts.where((h) => h.id == _hostId).firstOrNull;
    final check = chosen == null
        ? null
        : ref.watch(containerHostCheckProvider(chosen.id)).value;
    final canCreate = chosen != null && check?.canHost == true;
    final cores = check?.cores;
    final cpuChoices = [for (var n = 1; n <= (cores ?? 8).clamp(1, 16); n++) n];
    final memoryChoices = [
      for (final mb in _memoryChoices)
        if (check?.freeMemoryMb == null || mb <= check!.freeMemoryMb!) mb,
    ];
    final cpus = cpuChoices.contains(_cpus) ? _cpus : cpuChoices.last;
    final memoryMb = memoryChoices.contains(_memoryMb)
        ? _memoryMb
        : (memoryChoices.isEmpty ? _memoryMb : memoryChoices.last);
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // The whole dialog scrolls, title too: a long form on a phone at a large
    // text size leaves a fixed title no room for the fields.
    return AlertDialog(
      scrollable: true,
      // Its chips and host lines would otherwise widen it to their one-line
      // width; the form keeps its design width.
      constraints: const BoxConstraints(
        maxWidth: DialogWidth.regular + 2 * Insets.xl,
      ),
      title: const DesktopDialogTitle(
        icon: AppIcons.package,
        title: 'New Linux container',
        subtitle: 'Reached through the host it runs on.',
      ),
      content: SizedBox(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              DesktopErrorBanner(
                _error!,
                onDismiss: () => setState(() => _error = null),
              ),
              const SizedBox(height: Insets.md),
            ],
            TextField(
              key: const ValueKey('container-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'sandbox-1',
                helperText: 'Lower-case letters, digits, "-", "_" and ".".',
              ),
            ),
            const SizedBox(height: Insets.lg),
            Text('Runs on', style: label),
            const SizedBox(height: Insets.xs),
            if (hosts.isEmpty)
              Text(
                'Add an SSH host with Docker, or a WSL distribution, first.',
                style: theme.textTheme.bodySmall,
              )
            else
              RadioGroup<String>(
                groupValue: _hostId,
                onChanged: (id) => setState(() => _hostId = id),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (final host in hosts) _HostOption(host: host)],
                ),
              ),
            const SizedBox(height: Insets.lg),
            Text('Distribution', style: label),
            const SizedBox(height: Insets.xs),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                for (final distro in ContainerDistro.values)
                  ChoiceChip(
                    key: ValueKey('distro-${distro.name}'),
                    label: Text(distro.label),
                    selected: distro == _distro,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _distro = distro),
                  ),
              ],
            ),
            const SizedBox(height: Insets.lg),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: const ValueKey('container-cpus'),
                    initialValue: cpus,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'CPUs'),
                    items: [
                      for (final n in cpuChoices)
                        DropdownMenuItem(value: n, child: Text('$n')),
                    ],
                    onChanged: (n) => setState(() => _cpus = n ?? _cpus),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: const ValueKey('container-memory'),
                    initialValue: memoryChoices.isEmpty ? null : memoryMb,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Memory'),
                    items: [
                      for (final mb in memoryChoices)
                        DropdownMenuItem(
                          value: mb,
                          child: Text(formatMemory(mb)),
                        ),
                    ],
                    onChanged: (mb) =>
                        setState(() => _memoryMb = mb ?? _memoryMb),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.lg),
            Text('Comes with', style: label),
            const SizedBox(height: Insets.xs),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                for (final cli in ContainerAgentCli.values)
                  FilterChip(
                    key: ValueKey('agent-${cli.name}'),
                    label: Text(cli.label),
                    selected: _agents.contains(cli),
                    visualDensity: VisualDensity.compact,
                    onSelected: (on) => setState(
                      () => on ? _agents.add(cli) : _agents.remove(cli),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Its home folder is kept in a volume, so a container made '
              'again with the same name keeps your files.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_agents.isNotEmpty) ...[
              const SizedBox(height: Insets.xs),
              Text(
                'Node comes with them, from nodejs.org when the '
                'distribution\'s is too old.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
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
          key: const ValueKey('container-create'),
          onPressed: canCreate
              ? () {
                  _cpus = cpus;
                  _memoryMb = memoryMb;
                  _create(chosen, check);
                }
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// One host a container could run on: a radio, its name and kind, and what
/// its check found — greyed with the reason when it cannot.
class _HostOption extends ConsumerWidget {
  const _HostOption({required this.host});

  final ContainerHostChoice host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final check = ref.watch(containerHostCheckProvider(host.id));
    final reading = check.value;
    final canHost = reading?.canHost == true;
    final kind = host.isWsl ? 'WSL on this PC' : 'SSH';
    final help = theme.textTheme.bodySmall;
    final Widget line = switch (check) {
      AsyncValue(isLoading: true, value: null) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const InlineSpinner(),
          const SizedBox(width: Insets.xs),
          Text('Checking…', style: help),
        ],
      ),
      _ when canHost => Text(
        describeHostCheck(reading!),
        style: help?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      _ => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.xs,
        children: [
          Text(
            reading?.problem ?? 'Could not check it.',
            style: help?.copyWith(color: SemanticColors.of(context).attention),
          ),
          TextButton(
            onPressed: () =>
                ref.read(containerActionsProvider).recheck(host.id),
            child: const Text('Check again'),
          ),
        ],
      ),
    };
    return RadioListTile<String>(
      key: ValueKey('container-host-${host.id}'),
      value: host.id,
      enabled: canHost,
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${host.name} · $kind'),
      subtitle: line,
    );
  }
}
