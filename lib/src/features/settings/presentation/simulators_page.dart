import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../devices/application/ios_device_providers.dart';
import '../../devices/domain/simulator_slimming.dart';
import '../application/settings_controller.dart';
import 'settings_section.dart';

/// Which iOS Simulator background services a new simulator starts with.
///
/// macOS only — `simctl` ships with Xcode, and the nav hides this section
/// everywhere else.
///
/// Every category can be switched either way, and each says what stops working
/// if it is switched off. That is the whole point of the page: the right answer
/// depends on the app being built, and only the person building it knows
/// whether it needs the photo picker or push notifications. A page that just
/// said "slim: on" would leave them guessing at why the picker came up empty.
class SimulatorsPage extends ConsumerWidget {
  const SimulatorsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = ref.watch(slimmingOnStartProvider);
    final kept = ref.watch(slimmingKeptCategoriesProvider);
    final controller = ref.read(settingsControllerProvider.notifier);

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
      children: [
        SettingsSection(
          title: 'Slimming',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                onChanged: controller.setSimulatorSlimming,
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
            ],
          ),
        ),
        SettingsSection(
          title: 'Keep running',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
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
                  onChanged: enabled
                      ? (keep) => setKept(category, keep: keep)
                      : null,
                ),
            ],
          ),
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
    final losses = keep ? const <String>[] : category.featureLoss.values.toList();

    return CheckboxListTile(
      key: Key('slimming-${category.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: keep,
      onChanged: onChanged == null ? null : (value) => onChanged!(value ?? false),
      title: Row(
        children: [
          Expanded(child: Text(category.displayName)),
          Text(
            // A relative weight, never a total: these are medians measured one
            // category at a time, and the services share dirty pages, so
            // summing all fifteen overshoots what is actually saved.
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
