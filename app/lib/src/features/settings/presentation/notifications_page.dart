import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_notifications/policy.dart';

import '../../../app/shell/phone_routes.dart';
import '../../../app/shell/shell_area.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/phone_notifications.dart';
import '../../notifications/presentation/notify_level_text.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import 'settings_theme.dart';

/// Settings → Notifications: "Notify me", and on a desktop whether that waits
/// for the window to be in the background. The same
/// [notificationSettingsControllerProvider] the tray sets, so the two can
/// never disagree.
///
/// Drawn as [SettingsAnchor.notifications], under the heading the catalogue
/// gives it, so search and a link land on it.
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
      title: SettingsAnchor.notifications.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _NotifyMeChoice(),
          const _QuietItemsLink(),
          // It shapes only what does interrupt; dimmed, not hidden, at
          // Nothing, so choosing a level again shows what it will do.
          Opacity(
            opacity: settings.enabled ? 1 : 0.5,
            child: SettingsSwitchRow(
              label: 'Only while Karmashala is in the background',
              help: 'Quiet while you are looking at the window.',
              value: settings.onlyWhenUnfocused,
              onChanged: controller.setOnlyWhenUnfocused,
            ),
          ),
          SettingsSwitchRow(
            key: const ValueKey('settings-chime'),
            label: 'Chime when something needs you',
            help:
                'The system sound, once for each new question, approval or '
                'failed turn. Not while the Agent dashboard is in front of '
                'you, in Focus, with Notify me at Never, or while Windows '
                'asks for quiet.',
            value: settings.chime,
            onChanged: controller.setChime,
          ),
        ],
      ),
    );
  }
}

/// A phone's page (Stage 3 step 2): its own level, kept on this phone and
/// never at the server, so the desktop's toasts are untouched. There is no
/// "only in the background": a phone notifies in front too, for any session
/// but the one on screen. It notifies only while the app runs — no push.
class _PhoneNotificationsSection extends ConsumerWidget {
  const _PhoneNotificationsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked =
        ref.watch(phoneNotificationPermissionProvider).value == false;
    return SettingsSection(
      title: SettingsAnchor.notifications.heading,
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
                onPressed: () => openPhoneNotificationSettings(ref),
                child: const Text('Open settings'),
              ),
            ),
          const _NotifyMeChoice(
            help:
                'While Karmashala runs, for any session but the one on '
                'screen. Kept on this phone; the desktop’s are its own.',
          ),
          const _QuietItemsLink(),
        ],
      ),
    );
  }
}

/// "Notify me": the three levels, each with a line on what it does.
class _NotifyMeChoice extends ConsumerWidget {
  const _NotifyMeChoice({this.help});

  final String? help;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(
      notificationSettingsControllerProvider.select((s) => s.level),
    );
    final controller = ref.read(
      notificationSettingsControllerProvider.notifier,
    );
    return SettingsRuled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Notify me', style: SettingsStyles.rowLabel(context)),
          if (help case final help?)
            Text(help, style: SettingsStyles.rowHelp(context)),
          RadioGroup<NotifyLevel>(
            groupValue: level,
            onChanged: (chosen) {
              if (chosen != null) controller.setLevel(chosen);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final option in NotifyLevel.values)
                  RadioListTile<NotifyLevel>(
                    key: ValueKey('notify-level:${option.name}'),
                    value: option,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(notifyLevelLabel(option)),
                    subtitle: Text(notifyLevelHelp(option)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The way back to what was logged quietly: the Inbox, its quiet items shown.
class _QuietItemsLink extends ConsumerWidget {
  const _QuietItemsLink();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsRow(
    label: 'Quiet updates',
    help: 'What was logged without a notification, to read back.',
    control: TextButton(
      onPressed: () {
        ref.read(inboxShowQuietProvider.notifier).set(true);
        final phone = ref.read(phoneShellRouterProvider).current;
        if (phone != null) return phone.showInbox();
        showShellArea(ref, ShellArea.inbox);
      },
      child: const Text('Show in the Inbox'),
    ),
  );
}
