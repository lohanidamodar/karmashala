import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import '../../notifications/application/notification_providers.dart';

/// Each app's latest change set, as the server last told it: read off the
/// view the client already keeps, so a badge asks the server nothing.
class StoreChangesController extends Notifier<List<StoreAppChanges>> {
  @override
  List<StoreAppChanges> build() {
    final client = ref.watch(dataClientProvider);
    final changes = client.storesChanges.listen((view) {
      if (!_same(state, view.changes)) state = view.changes;
    });
    ref.onDispose(changes.cancel);
    return client.storesView?.changes ?? const [];
  }

  /// Seen here at once, before the server's answer comes back.
  void seenHere(Set<String> appKeys) {
    state = [
      for (final held in state)
        appKeys.contains(held.app.key) ? held.asSeen() : held,
    ];
  }

  static bool _same(List<StoreAppChanges> a, List<StoreAppChanges> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].app.key != b[i].app.key ||
          a[i].at != b[i].at ||
          a[i].seen != b[i].seen) {
        return false;
      }
    }
    return true;
  }
}

final storeChangesProvider =
    NotifierProvider<StoreChangesController, List<StoreAppChanges>>(
      StoreChangesController.new,
    );

/// The Stores badge: apps whose unseen changes want a person.
final storesUnseenAttentionProvider = Provider<int>(
  (ref) => ref
      .watch(storeChangesProvider)
      .where((held) => !held.seen && held.attention)
      .length,
);

/// Whether some app changed in a way nobody has looked at that does not want
/// a person: the Stores glyph's neutral dot.
final storesUnseenNewsProvider = Provider<bool>(
  (ref) => ref
      .watch(storeChangesProvider)
      .any((held) => !held.seen && !held.attention),
);

/// A wish to show one app in the Stores tab, from code holding no widget
/// ref: a notification clicked, an inbox item opened in any window.
class StoresOpenRequest {
  const StoresOpenRequest(this.appKey, this.serial);

  final String appKey;

  /// Tells two requests for the same app apart.
  final int serial;
}

class StoresOpenRequests extends Notifier<StoresOpenRequest?> {
  int _serial = 0;

  @override
  StoresOpenRequest? build() => null;

  void open(String appKey) => state = StoresOpenRequest(appKey, ++_serial);
}

final storesOpenRequestProvider =
    NotifierProvider<StoresOpenRequests, StoresOpenRequest?>(
      StoresOpenRequests.new,
    );

/// The notification for what one read of the stores found, as [settings]
/// allow it: null when nothing is to interrupt. One app is named with its
/// changes; several are counted. A click opens the first app.
NotificationRequest? storeChangeNotification(
  List<StoreAppChanges> found,
  NotificationSettings settings,
) {
  if (settings.level == NotifyLevel.nothing) return null;
  final told = switch (settings.storeChanges) {
    StoreChangeNotify.off => const <StoreAppChanges>[],
    StoreChangeNotify.attention => [
      for (final held in found)
        if (held.attention) held,
    ],
    StoreChangeNotify.everything => found,
  };
  if (told.isEmpty) return null;
  final loud = told.any((held) => held.attention);
  final payload = NotificationPayload(
    openId: storeInboxOpenId(told.first.app.key),
    imported: false,
  ).encode();
  if (told.length == 1) {
    final only = told.single;
    return NotificationRequest(
      title: only.title,
      body: only.summary,
      payload: payload,
      quiet: !loud,
    );
  }
  return NotificationRequest(
    title: '${told.length} apps changed in the stores',
    body: [for (final held in told) held.title].join(' · '),
    payload: payload,
    quiet: !loud,
  );
}

/// Shows what each read of the stores found, judged against Settings →
/// Notifications and, on a desktop, the window's focus. Must be watched.
class StoreChangeNotices extends Notifier<int> {
  @override
  int build() {
    final notices = ref
        .watch(dataClientProvider)
        .storeChangeNotices
        .listen(present);
    ref.onDispose(notices.cancel);
    return 0;
  }

  void present(List<StoreAppChanges> found) {
    final settings = ref.read(notificationSettingsControllerProvider);
    // A phone tells in front too, as it does for agents; a desktop waits for
    // the window to be away when asked to.
    final phone = ref.read(capabilitiesProvider).localNotifications;
    if (!phone &&
        settings.onlyWhenUnfocused &&
        ref.read(windowFocusedProvider)) {
      return;
    }
    final request = storeChangeNotification(found, settings);
    if (request == null) return;
    state++;
    unawaited(ref.read(notificationPresenterProvider).show(request));
  }
}

final storeChangeNoticesProvider = NotifierProvider<StoreChangeNotices, int>(
  StoreChangeNotices.new,
);
