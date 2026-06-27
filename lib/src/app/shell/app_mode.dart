import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/settings/application/settings_controller.dart';

/// The app's window mode: the full desktop shell, or a small borderless mini
/// launcher (projects + sessions only).
enum AppMode { full, mini }

/// Switches the window between full and mini mode, resizing/reframing the native
/// window. Window calls are desktop-only and guarded.
class AppModeController extends Notifier<AppMode> {
  static const _miniSize = Size(340, 480);

  @override
  AppMode build() => AppMode.full;

  bool get _supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  Future<void> enterMini() async {
    await _applyMini();
    state = AppMode.mini;
  }

  Future<void> enterFull() async {
    await _applyFull();
    state = AppMode.full;
  }

  Future<void> toggle() => state == AppMode.mini ? enterFull() : enterMini();

  Future<void> _applyMini() async {
    if (!_supported) return;
    try {
      await windowManager.setMinimumSize(const Size(260, 320));
      await windowManager.setSize(_miniSize);
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _applyFull() async {
    if (!_supported) return;
    try {
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(const Size(720, 560));
      final settings = ref.read(settingsControllerProvider);
      final size =
          (settings.windowWidth != null && settings.windowHeight != null)
          ? Size(settings.windowWidth!, settings.windowHeight!)
          : const Size(1200, 800);
      await windowManager.setSize(size);
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }
}

final appModeProvider = NotifierProvider<AppModeController, AppMode>(
  AppModeController.new,
);
