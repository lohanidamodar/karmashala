import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../application/ios_device_providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'device_section_header.dart';
import 'simulator_slimming_dialog.dart';

/// The iOS Simulators section: a picker plus a Start button, not a list —
/// Xcode accumulates 170 here. Off macOS the section disappears entirely.
class SimulatorList extends ConsumerStatefulWidget {
  const SimulatorList({super.key});

  @override
  ConsumerState<SimulatorList> createState() => _SimulatorListState();
}

class _SimulatorListState extends ConsumerState<SimulatorList> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(hostCanRunSimulatorsProvider)) {
      return const SizedBox.shrink();
    }
    final anyBooted = ref.watch(bootedSimulatorsProvider).isNotEmpty;
    final startable = ref.watch(startableSimulatorsProvider);
    final busy = ref.watch(simulatorTransitionsProvider);
    final transitions = ref.read(simulatorTransitionsProvider.notifier);

    // A booted simulator keeps the section alive with nothing left to start:
    // the Slimming button and the switch below govern the *next* boot.
    if (startable.isEmpty && !anyBooted) return const SizedBox.shrink();

    // A simulator picked and since started is no longer in the list it was
    // picked from; falling back keeps the picker on something real.
    final picked = startable.any((s) => s.udid == _picked)
        ? _picked
        : (startable.isEmpty ? null : startable.first.udid);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        DeviceSectionHeader(
          title: 'iOS Simulators',
          action: TextButton(
            key: const Key('simulator-slimming-open'),
            onPressed: () => SimulatorSlimmingDialog.show(context),
            child: const Text('Slimming'),
          ),
        ),
        if (startable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: const Key('simulator-picker'),
                    initialValue: picked,
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final simulator in startable)
                        DropdownMenuItem(
                          value: simulator.udid,
                          child: Text(
                            simulator.displayName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => _picked = value),
                  ),
                ),
                const SizedBox(width: 8),
                _StartButton(
                  // Booting is slow — ten seconds and up — and nothing else
                  // on screen changes, so the button has to say so itself.
                  busy: picked != null && busy.contains(picked),
                  onPressed: picked == null
                      ? null
                      : () => transitions.boot(picked),
                ),
              ],
            ),
          ),
        _SlimOnStart(booted: anyBooted),
      ],
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      key: const Key('start-simulator'),
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Start'),
    );
  }
}

/// The "slim it when it starts" switch. launchd reads `disabled.plist` at
/// boot, so it can only apply to one that is *starting*, and it says so.
class _SlimOnStart extends ConsumerWidget {
  const _SlimOnStart({required this.booted});

  /// Whether any simulator is currently running.
  final bool booted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = ref.watch(slimmingOnStartProvider);
    final kept = ref.watch(slimmingKeptCategoriesProvider);
    final trimmed = SlimmingCategory.values.length - kept.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const Key('slim-on-start'),
          dense: true,
          controlAffinity: ListTileControlAffinity.trailing,
          contentPadding: const EdgeInsets.only(left: 16, right: 12),
          value: enabled,
          title: const Text('Slim on start'),
          subtitle: Text(
            enabled
                ? 'Starts without $trimmed groups of background services. '
                      'Choose which under Slimming, above.'
                : 'Starts with every background service iOS ships.',
            style: theme.textTheme.bodySmall,
          ),
          onChanged: (value) => ref
              .read(settingsControllerProvider.notifier)
              .setSimulatorSlimming(value ?? false),
        ),
        if (enabled && booted)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'A running simulator keeps the services it booted with. Stop and '
              'start it to slim it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
