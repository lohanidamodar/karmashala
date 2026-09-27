/// A device an agent holds (the server's claims, slice 4a), as a person meets
/// it in the pane: who holds it, and a question before a person's own action
/// lands on it. The person is never refused — the device is theirs — but they
/// are never surprised either.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/device_ports.dart';

/// The holds a person has said to act through, by claim — a new claim (a new
/// holder, or the same one after a lapse) asks again.
class HeldDeviceOverrides extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  static String keyOf(DeviceClaim claim) =>
      '${claim.deviceId} ${claim.holderSessionId} '
      '${claim.takenAt.toIso8601String()}';

  bool covers(DeviceClaim claim) => state.contains(keyOf(claim));

  void allow(DeviceClaim claim) => state = {...state, keyOf(claim)};
}

final heldDeviceOverridesProvider =
    NotifierProvider<HeldDeviceOverrides, Set<String>>(
      HeldDeviceOverrides.new,
    );

/// The claim on [deviceId] a person has not yet said to act through, or null.
DeviceClaim? unansweredHoldOn(WidgetRef ref, String deviceId) {
  final held = ref.watch(deviceHoldersProvider)[deviceId];
  if (held == null) return null;
  ref.watch(heldDeviceOverridesProvider);
  return ref.read(heldDeviceOverridesProvider.notifier).covers(held)
      ? null
      : held;
}

/// Asks whether to act on a device an agent is driving; [sentence] is the
/// holder's own refusal, so the question names who, since when and doing what.
Future<bool> confirmActOnHeldDevice(
  BuildContext context,
  String sentence,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('An agent is driving this device'),
        content: SelectableText(sentence),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Leave it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Act anyway'),
          ),
        ],
      ),
    ) ??
    false;

/// Whether a person's [verb] on [deviceId] may go ahead: at once when nobody
/// holds it or the person already said so for this hold, else after asking.
Future<bool> mayActOnDevice(
  BuildContext context,
  WidgetRef ref,
  String deviceId,
  String verb,
) async {
  final held = ref.read(deviceHoldersProvider)[deviceId];
  if (held == null) return true;
  final overrides = ref.read(heldDeviceOverridesProvider.notifier);
  if (overrides.covers(held)) return true;
  final now = ref.read(deviceClockProvider).nowUtc();
  final anyway = await confirmActOnHeldDevice(
    context,
    deviceBusyMessage(verb, held, now),
  );
  if (anyway) overrides.allow(held);
  return anyway;
}

/// Laid over the live picture of a held device until the person says to take
/// over: taps and keys do not reach a device an agent is driving by accident.
class HeldDeviceCover extends ConsumerWidget {
  const HeldDeviceCover({required this.claim, super.key});

  final DeviceClaim claim;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = ref.watch(deviceClockProvider).nowUtc();
    return ColoredBox(
      color: theme.colorScheme.surface.withValues(alpha: 0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Driven by ${claim.holderLabel}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                'Since ${describeDriveAge(now.difference(claim.takenAt))}, '
                'last ${claim.lastVerb} '
                '${describeDriveAge(now.difference(claim.lastCallAt))}.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.sm),
              FilledButton(
                key: const Key('device-take-over'),
                onPressed: () async {
                  if (await confirmActOnHeldDevice(
                    context,
                    deviceBusyMessage('tap', claim, now),
                  )) {
                    ref.read(heldDeviceOverridesProvider.notifier).allow(claim);
                  }
                },
                child: const Text('Take over'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
