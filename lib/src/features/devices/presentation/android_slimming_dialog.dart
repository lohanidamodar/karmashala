import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../settings/application/settings_controller.dart';
import '../application/device_providers.dart';
import '../domain/android_device.dart';
import '../domain/android_slimming.dart';

/// What an Android emulator starts with, and what gets switched off inside it.
///
/// A dialog rather than a settings page because it is a decision about the
/// Start button three rows below it, and because two of its three groups are
/// **not** a preference at all: they are changes written into the emulator that
/// stay there. Every layer says so above its own tick boxes, and Restore is on
/// the same screen rather than somewhere a user has to go looking for it after
/// their Firebase build stops working.
///
/// The tick boxes read the opposite way round from the iOS Simulator page:
/// there a tick *spares* a category, here it *applies* one. Android's risky
/// layer is opt-in, so "ticked means something happens" is the honest polarity,
/// and it is why the feature-loss warnings show while a box is ticked.
class AndroidSlimmingDialog extends ConsumerWidget {
  const AndroidSlimmingDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const AndroidSlimmingDialog(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = ref.watch(androidSlimmingOnStartProvider);
    final selected = categoriesFromIds(
      ref.watch(
        settingsControllerProvider.select((s) => s.androidSlimmingEnabled),
      ),
    );
    final controller = ref.read(settingsControllerProvider.notifier);

    void setSelected(AndroidSlimmingCategory category, {required bool apply}) {
      final next = {...selected};
      if (apply) {
        next.add(category);
      } else {
        next.remove(category);
      }
      controller.setAndroidSlimmingEnabled([for (final c in next) c.id]);
    }

    return AlertDialog(
      title: const Text('Emulator slimming'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                key: const Key('android-slimming-enabled'),
                contentPadding: EdgeInsets.zero,
                value: enabled,
                title: const Text('Slim emulators when they start'),
                subtitle: const Text(
                  'Measured on an API 34 emulator here: with the package '
                  'groups below switched on too, 373 processes down to 312 and '
                  'used RAM 1.40 GB down to 1.07 GB. The flags and animation '
                  'groups on their own cost nothing and break nothing — they '
                  'buy a device that settles instantly when you drive it. The '
                  'packages are where the memory is.',
                ),
                onChanged: controller.setAndroidSlimming,
              ),
              const SizedBox(height: Insets.md),
              _GpuPicker(enabled: true),
              for (final layer in AndroidSlimmingLayer.values)
                _LayerSection(
                  layer: layer,
                  selected: selected,
                  // Nothing is applied at all while slimming is off, so
                  // offering the choice would be a lie about what will happen.
                  onChanged: enabled ? setSelected : null,
                ),
              const Divider(height: Insets.xl),
              const _RestoreRow(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
      actionsPadding: const EdgeInsets.fromLTRB(
        Insets.lg,
        0,
        Insets.lg,
        Insets.md,
      ),
      titleTextStyle: theme.textTheme.titleMedium,
    );
  }
}

class _GpuPicker extends ConsumerWidget {
  const _GpuPicker({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = ref.watch(androidEmulatorGpuProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Renderer', style: theme.textTheme.labelLarge),
        const SizedBox(height: Insets.xs),
        DropdownButtonFormField<AndroidGpuMode>(
          key: const Key('android-gpu-mode'),
          initialValue: mode,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final option in AndroidGpuMode.values)
              DropdownMenuItem(
                value: option,
                child: Text(
                  option.displayName,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: enabled
              ? (value) => ref
                    .read(settingsControllerProvider.notifier)
                    .setAndroidEmulatorGpu((value ?? AndroidGpuMode.auto).id)
              : null,
        ),
        Padding(
          padding: const EdgeInsets.only(top: Insets.xs),
          child: Text(
            // The one choice here that can break the pane outright, so the
            // consequence is on screen rather than in a tooltip.
            '${mode.description} This pane streams the emulator\'s screen, so '
            'a renderer the host cannot drive shows a black preview.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _LayerSection extends StatelessWidget {
  const _LayerSection({
    required this.layer,
    required this.selected,
    required this.onChanged,
  });

  final AndroidSlimmingLayer layer;
  final Set<AndroidSlimmingCategory> selected;
  final void Function(AndroidSlimmingCategory category, {required bool apply})?
  onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = AndroidSlimmingCategory.inLayer(layer);
    if (categories.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(layer.displayName, style: theme.textTheme.labelLarge),
              const SizedBox(width: Insets.sm),
              if (layer.persists)
                // The single most important thing on this dialog: unlike the
                // iOS side, switching slimming off does not undo these.
                Chip(
                  key: Key('android-slimming-persists-${layer.id}'),
                  label: const Text('Stays on the emulator'),
                  visualDensity: VisualDensity.compact,
                  labelStyle: theme.textTheme.labelSmall,
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.xs),
            child: Text(
              layer.note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final category in categories)
            _CategoryTile(
              category: category,
              apply: selected.contains(category),
              onChanged: onChanged == null
                  ? null
                  : (apply) => onChanged!(category, apply: apply),
            ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.apply,
    required this.onChanged,
  });

  final AndroidSlimmingCategory category;
  final bool apply;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Shown only while the category is about to be applied: a warning about
    // something that is not happening is noise.
    final losses = apply
        ? category.featureLoss.values.toList()
        : const <String>[];

    return CheckboxListTile(
      key: Key('android-slimming-${category.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: apply,
      onChanged: onChanged == null
          ? null
          : (value) => onChanged!(value ?? false),
      title: Text(category.displayName),
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

/// Puts a running emulator back the way it was.
///
/// Only offered for a running emulator, because both durable layers are `adb`
/// calls and there is nothing to talk to otherwise. A physical device is never
/// offered: nothing here has ever touched one, so there would be nothing to
/// restore.
class _RestoreRow extends ConsumerWidget {
  const _RestoreRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final devices =
        ref.watch(devicesProvider).asData?.value ?? const <AndroidDevice>[];
    final emulators = [
      for (final device in devices)
        if (device.isEmulator && device.isReady) device,
    ];
    final busy = ref.watch(androidSlimmingProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Restore', style: theme.textTheme.labelLarge),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          child: Text(
            emulators.isEmpty
                ? 'Start the emulator you want to put back — the settings and '
                      'packages above are changed on the device, so restoring '
                      'them needs it running.'
                : 'Puts back every setting and package this app disabled, on a '
                      'running emulator. Packages something else disabled are '
                      'left alone.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final emulator in emulators)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Row(
              children: [
                Expanded(child: Text(emulator.displayName)),
                OutlinedButton(
                  key: Key('android-slimming-restore-${emulator.serial}'),
                  onPressed: busy.contains(emulator.serial)
                      ? null
                      : () async {
                          final report = await ref
                              .read(androidSlimmingProvider.notifier)
                              .restore(emulator.serial);
                          if (!context.mounted || report == null) return;
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(
                              content: Text(
                                report.ok
                                    ? 'Restored ${report.applied.length} '
                                          'setting(s) and package(s) on '
                                          '${emulator.serial}.'
                                    : 'Restored ${report.applied.length}, '
                                          'could not restore '
                                          '${report.failed.keys.join(', ')}.',
                              ),
                            ),
                          );
                        },
                  child: busy.contains(emulator.serial)
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Restore'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
