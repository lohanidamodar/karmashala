import 'package:riverpod/riverpod.dart';

import 'app_console_feed.dart';
import 'attached_apps.dart';

/// Which attached app the pane is about, or `null` for "no explicit choice" —
/// per-surface, so a panel cannot decide which app an MCP call means.
class SelectedFlutterAppId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedFlutterAppIdProvider =
    NotifierProvider<SelectedFlutterAppId, String?>(SelectedFlutterAppId.new);

/// The app the pane is describing: the explicit choice, or the only attached
/// one. Derived, so the pane and its actions cannot hold two opinions.
final paneFlutterAppIdProvider = Provider<String?>((ref) {
  final registry = ref.watch(attachedAppsProvider);
  final chosen = ref.watch(selectedFlutterAppIdProvider);
  if (chosen != null && registry.byId(chosen) != null) return chosen;
  return registry.onlyAttached?.id ??
      (registry.apps.length == 1 ? registry.apps.single.id : null);
});

/// A tick per console batch, so the console repaints without the lines
/// living in the registry.
final flutterAppConsoleTickProvider = StreamProvider.autoDispose
    .family<int, String>((ref, appId) {
      final feed = ref.watch(appConsoleFeedProvider(appId));
      if (feed == null) return const Stream<int>.empty();
      return feed.ticks;
    });
