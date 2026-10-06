import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_notifications/policy.dart';

import '../../sessions/application/session_list_prefs.dart';
import 'notification_providers.dart';

/// Focus: "Notify me" at Only when I'm needed and Hide while working on, and
/// off, both put back as they were. Kept with the notification settings as
/// what it replaced ([NotificationSettings.focus]), so it outlives a restart;
/// nothing else is stored.
class FocusModeController extends Notifier<bool> {
  @override
  bool build() => ref.watch(
    notificationSettingsControllerProvider.select((s) => s.focus != null),
  );

  void set(bool on) {
    final settings = ref.read(notificationSettingsControllerProvider);
    final notifications = ref.read(
      notificationSettingsControllerProvider.notifier,
    );
    final lists = ref.read(sessionListPrefsProvider.notifier);
    final before = settings.focus;
    if (on) {
      if (before != null) return;
      notifications.startFocus(
        FocusMemory(
          level: settings.level,
          hideWorking: ref.read(hideWorkingSessionsProvider),
        ),
      );
      lists.setHideWorking(true);
      return;
    }
    if (before == null) return;
    notifications.endFocus();
    lists.setHideWorking(before.hideWorking);
  }

  void toggle() => set(!state);
}

final focusModeProvider = NotifierProvider<FocusModeController, bool>(
  FocusModeController.new,
);
