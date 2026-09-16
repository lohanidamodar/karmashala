import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/device_ports.dart';
import '../application/ios_device_providers.dart';
import '../../devices.dart';

/// What an iOS simulator starts with, and what is switched off inside it.
/// A tick *spares* a category here; on the Android dialog a tick applies one.
class SimulatorSlimmingDialog extends ConsumerWidget {
  const SimulatorSlimmingDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const SimulatorSlimmingDialog(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('Simulator slimming'),
      content: const BoundedDialogContent(
        width: DialogWidth.regular,
        child: SimulatorSlimmingSettings(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The simulator slimming choices themselves, shared by the dialog and the
/// app's Settings page so the two cannot drift.
class SimulatorSlimmingSettings extends ConsumerWidget {
  const SimulatorSlimmingSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canRun = ref.watch(hostCanRunSimulatorsProvider);
    final enabled = ref.watch(slimmingOnStartProvider);
    final kept = ref.watch(slimmingKeptCategoriesProvider);
    final controller = ref.read(deviceSlimmingPreferencesProvider.notifier);

    void setKept(SlimmingCategory category, {required bool keep}) {
      final next = {...kept};
      if (keep) {
        next.add(category);
      } else {
        next.remove(category);
      }
      controller.setSimulatorSlimmingKept([for (final c in next) c.id]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          key: const Key('slimming-enabled'),
          contentPadding: EdgeInsets.zero,
          value: enabled,
          title: const Text('Slim simulators when they start'),
          subtitle: const Text(
            'A stock iOS simulator boots around 358 background services '
            'to serve a user who is not there. Switching off the ones '
            'below took memory from 3.1 GB to 0.9 GB and boot from 15.8s '
            'to 9.6s on an iPhone 17.',
          ),
          // Off and fixed where simulators cannot run: the stored choice
          // would do nothing here.
          onChanged: canRun ? controller.setSimulatorSlimming : null,
        ),
        const SizedBox(height: Insets.sm),
        Text(
          // The one thing about this that surprises people. launchd reads
          // the file at boot, so nothing here can reach a running device.
          'Applied when a simulator starts. A simulator that is already '
          'running keeps the services it booted with — stop and start it '
          'to slim it.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (!canRun)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              'iOS simulators run only on a Mac, so nothing here applies '
              'on this computer.',
              key: const Key('slimming-host-cannot-run'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const Divider(height: Insets.xl),
        Text('Keep running', style: theme.textTheme.titleSmall),
        Padding(
          padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
          child: Text(
            'Ticked groups keep running. The three ticked by default are '
            'the ones a Flutter app is most likely to need and whose '
            'absence is hardest to diagnose — untick them if your app '
            'has no push notifications, photo picker or universal links.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final category in SlimmingCategory.values)
          _CategoryTile(
            category: category,
            keep: kept.contains(category),
            // Nothing is switched off at all while slimming is off, so
            // offering the choice would be a lie about what will happen.
            onChanged: enabled ? (keep) => setKept(category, keep: keep) : null,
          ),
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.keep,
    required this.onChanged,
  });

  final SlimmingCategory category;
  final bool keep;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Only shown when the category is about to be switched off: a warning about
    // something that is still running is noise.
    final losses = keep
        ? const <String>[]
        : category.featureLoss.values.toList();

    return CheckboxListTile(
      key: Key('slimming-${category.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: keep,
      onChanged: onChanged == null
          ? null
          : (value) => onChanged!(value ?? false),
      title: Row(
        children: [
          Expanded(child: Text(category.displayName)),
          Text(
            // A relative weight, never a total: these are medians measured
            // one category at a time, and the services share dirty pages.
            '~${category.approxSavingMb} MB',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(category.description, style: theme.textTheme.bodySmall),
          for (final loss in losses)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                loss,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
