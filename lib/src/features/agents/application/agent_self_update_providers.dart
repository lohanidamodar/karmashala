import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../settings/application/settings_controller.dart';

/// Whether an agent Karmashala launches may update itself in that session.
///
/// Resolves the [Settings.letAgentsUpdateThemselves] tri-state: an explicit
/// choice wins, and **unset defaults to off on Windows, on elsewhere**. The
/// asymmetry is where the harm was measured — Bitdefender on the owner's
/// managed Windows machine killed the process tree when a launched Codex tried
/// to self-update (docs/windows-antivirus.md) — while on macOS and Linux a
/// self-update is unremarkable, so nothing is taken away by default.
final agentsMayUpdateThemselvesProvider = Provider<bool>((ref) {
  final setting = ref
      .watch(settingsControllerProvider)
      .letAgentsUpdateThemselves;
  return setting ?? !Platform.isWindows;
});

/// The default when the setting is unset, exposed for the settings surface so
/// the toggle shows the value a launch would actually use.
bool defaultLetAgentsUpdateThemselves({bool? isWindows}) =>
    !(isWindows ?? Platform.isWindows);
