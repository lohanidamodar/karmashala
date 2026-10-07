import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../overview/application/overview_on_screen.dart';
import '../data/os_quiet.dart';
import 'attention_inbox.dart';
import 'focus_mode.dart';
import 'notification_providers.dart';

/// The platform's own notification sound. A test puts a recorder here.
final chimeSoundProvider = Provider<void Function()>(
  (ref) =>
      () => SystemSound.play(SystemSoundType.alert),
);

/// Whether the OS asks for quiet now; null where nothing reads it.
final osQuietProvider = Provider<bool? Function()>((ref) => osAsksForQuiet);

/// What needs the person: an ask, or a turn that failed.
const Set<InboxItemKind> kChimeKinds = {
  InboxItemKind.needsApproval,
  InboxItemKind.failed,
};

/// Why the chime holds back now, or null when it plays.
String? chimeHeldBecause({
  required NotificationSettings settings,
  required bool phone,
  required bool focusMode,
  required bool? osQuiet,
  required bool windowFocused,
  required bool dashboardOnScreen,
}) {
  if (!settings.chime) return 'off';
  // The phone has its own notifications.
  if (phone) return 'on the phone';
  if (focusMode) return 'Focus is on';
  if (settings.level == NotifyLevel.nothing) return 'Notify me is Never';
  if (osQuiet ?? false) return 'the OS asks for quiet';
  if (windowFocused && dashboardOnScreen) return 'it is on screen';
  return null;
}

/// **The chime**: once for each new thing that needs the person, never for
/// the same item again — even one it held back for.
class NeedsYouChime {
  NeedsYouChime({required this.heldBecause, required this.play});

  /// [chimeHeldBecause], asked of the app as it is now.
  final String? Function() heldBecause;
  final void Function() play;
  final _heard = <String>{};

  static Iterable<String> _needsYou(List<InboxItem> items) => [
    for (final item in items)
      if (kChimeKinds.contains(item.kind)) item.id,
  ];

  /// What already waits is not new.
  void seed(List<InboxItem> items) => _heard.addAll(_needsYou(items));

  void onInbox(List<InboxItem> items) {
    var fresh = false;
    for (final id in _needsYou(items)) {
      if (_heard.add(id)) fresh = true;
    }
    if (fresh && heldBecause() == null) play();
  }
}

/// Listening from its first read for the app's life; the desktop reads it
/// once it has a window.
final needsYouChimeProvider = Provider<NeedsYouChime>((ref) {
  final chime = NeedsYouChime(
    heldBecause: () => chimeHeldBecause(
      settings: ref.read(notificationSettingsControllerProvider),
      phone: ref.read(clientCapabilitiesProvider).localNotifications,
      focusMode: ref.read(focusModeProvider),
      osQuiet: ref.read(osQuietProvider)(),
      windowFocused: ref.read(windowFocusedProvider),
      dashboardOnScreen: ref.read(overviewOnScreenProvider) > 0,
    ),
    play: () => ref.read(chimeSoundProvider)(),
  )..seed(ref.read(attentionInboxProvider).items);
  ref.listen(attentionInboxProvider, (_, next) => chime.onInbox(next.items));
  return chime;
});
