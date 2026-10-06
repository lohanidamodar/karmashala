import 'package:karmashala_notifications/policy.dart';

/// "Notify me"'s words for each level, shared by the settings page, the tray
/// and quick open so they cannot come to name a level differently.
String notifyLevelLabel(NotifyLevel level) => switch (level) {
  NotifyLevel.everything => 'Everything',
  NotifyLevel.whenNeeded => 'Only when I’m needed',
  NotifyLevel.nothing => 'Nothing',
};

/// One line on what [level] does.
String notifyLevelHelp(NotifyLevel level) => switch (level) {
  NotifyLevel.everything =>
    'Finished turns, asks, failures and pull request news.',
  NotifyLevel.whenNeeded =>
    'Only an ask, a failure, failed checks or requested changes. Finished '
        'turns and the rest wait quietly in the Inbox.',
  NotifyLevel.nothing => 'No notifications. The Inbox still keeps everything.',
};
