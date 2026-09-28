import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Notifications: the four switches that were only ever in the tray
/// menu (two of them) or nowhere at all. The same
/// [notificationSettingsControllerProvider] the tray toggles, so the two can
/// never disagree.
///
/// Drawn by the settings screen for its page rather than through an anchor:
/// the anchor table lives in `settings_page_body.dart`, which the responsive
/// work owns. Move it there as `SettingsAnchor.notifications` when that settles.
class NotificationsSection extends ConsumerWidget {
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(notificationSettingsControllerProvider);
    final controller = ref.read(
      notificationSettingsControllerProvider.notifier,
    );
    return SettingsSection(
      title: 'DESKTOP NOTIFICATIONS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Send desktop notifications',
            help:
                'Off, nothing is sent; the Inbox and the tray still show what '
                'needs you.',
            value: settings.enabled,
            onChanged: controller.setEnabled,
          ),
          // The rest only shape what the master switch lets through; dimmed,
          // not hidden, so turning it back on shows what it will do.
          Opacity(
            opacity: settings.enabled ? 1 : 0.5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSwitchRow(
                  label: 'Only while Karmashala is in the background',
                  help: 'Quiet while you are looking at the window.',
                  value: settings.onlyWhenUnfocused,
                  onChanged: controller.setOnlyWhenUnfocused,
                ),
                SettingsSwitchRow(
                  label: 'When an agent needs you',
                  help: 'Waiting for an approval, or failed.',
                  value: settings.notifyWhenAttentionNeeded,
                  onChanged: controller.setNotifyWhenAttentionNeeded,
                ),
                SettingsSwitchRow(
                  label: 'When an agent finishes',
                  help: 'A turn ended and the agent stopped working.',
                  value: settings.notifyWhenFinished,
                  onChanged: controller.setNotifyWhenFinished,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
