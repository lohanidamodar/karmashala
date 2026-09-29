import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/phone_notifications.dart';
import '../../notifications/data/phone_notification_presenter.dart';
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
    if (ref.watch(capabilitiesProvider).localNotifications) {
      return const _PhoneNotificationsSection();
    }
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

/// A phone's page (Stage 3 step 2): its own switches, kept on this phone and
/// never at the server, so the desktop's toasts are untouched. There is no
/// "only in the background": a phone notifies in front too, for any session
/// but the one on screen. It notifies only while the app runs — no push.
class _PhoneNotificationsSection extends ConsumerWidget {
  const _PhoneNotificationsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(notificationSettingsControllerProvider);
    final controller = ref.read(
      notificationSettingsControllerProvider.notifier,
    );
    final blocked =
        ref.watch(phoneNotificationPermissionProvider).value == false;
    return SettingsSection(
      title: 'NOTIFICATIONS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (blocked)
            SettingsRow(
              label: 'Notifications are off for Karmashala',
              help:
                  'The phone blocks them, so nothing below is sent. Allow '
                  'them in the phone’s settings.',
              control: TextButton(
                onPressed: () {
                  final presenter = ref.read(notificationPresenterProvider);
                  if (presenter is PhoneNotificationPresenter) {
                    unawaited(presenter.openSystemSettings());
                  }
                },
                child: const Text('Open settings'),
              ),
            ),
          SettingsSwitchRow(
            label: 'Send notifications on this phone',
            help:
                'While Karmashala runs, for any session but the one on '
                'screen. Kept on this phone; the desktop’s are its own.',
            value: settings.enabled,
            onChanged: controller.setEnabled,
          ),
          Opacity(
            opacity: settings.enabled ? 1 : 0.5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
