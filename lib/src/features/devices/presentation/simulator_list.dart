import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../application/ios_device_providers.dart';
import '../domain/simulator_slimming.dart';
import 'device_section_header.dart';
import 'simulator_slimming_dialog.dart';

/// The iOS Simulators section of the device sidebar.
///
/// A **picker plus a Start button**, not a list of every simulator. Xcode
/// accumulates them: this developer's machine holds 170, of which 124 have no
/// installed runtime and 46 can actually be started. Listing all of them would
/// bury the Android devices above and give a user 170 rows to read to find the
/// iPhone they meant.
///
/// A booted simulator is **not** listed here: it is a connected device, and it
/// belongs with the others under Connected rather than beneath the idle ones.
///
/// The whole section disappears off macOS rather than showing an empty state.
/// Windows and Linux cannot have simulators at all, and a permanently empty
/// "iOS Simulators" heading is a question the user cannot answer.
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

    if (startable.isEmpty) return const SizedBox.shrink();

    // A simulator that was picked and has since started is no longer in the
    // list it was picked from; falling back keeps the picker on something real
    // rather than showing a blank selection.
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
                  // Booting is slow — ten seconds and up — and nothing else on
                  // screen changes while it happens, so the button has to say
                  // so itself.
                  busy: picked != null && busy.contains(picked),
                  onPressed: picked == null
                      ? null
                      : () => transitions.boot(picked),
                ),
              ],
            ),
          ),
        if (startable.isNotEmpty) _SlimOnStart(booted: anyBooted),
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

/// The "slim it when it starts" switch, and the one thing about it that
/// surprises people.
///
/// launchd reads `disabled.plist` when the device boots, so this can only ever
/// apply to a simulator that is *starting*. Turning it on while one is already
/// running does nothing to that one, and a switch that silently does nothing is
/// worse than no switch — so when something is booted, it says what to do.
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
