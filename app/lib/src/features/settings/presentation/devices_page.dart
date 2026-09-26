import 'package:flutter/material.dart';
import 'package:karmashala_devices/widgets.dart';

import 'settings_catalog.dart';
import 'settings_section.dart';

/// Settings → Devices → Android emulators: the same controls as the device
/// pane's Emulators › Slimming, less Restore, which acts on a running
/// emulator and stays beside it.
class AndroidEmulatorsSection extends StatelessWidget {
  const AndroidEmulatorsSection({super.key});

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: SettingsAnchor.androidEmulators.heading,
    child: const AndroidSlimmingSettings(showRestore: false),
  );
}

/// Settings → Devices → iOS simulators: the device pane's iOS Simulators ›
/// Slimming.
class IosSimulatorsSection extends StatelessWidget {
  const IosSimulatorsSection({super.key});

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: SettingsAnchor.iosSimulators.heading,
    child: const SimulatorSlimmingSettings(),
  );
}
