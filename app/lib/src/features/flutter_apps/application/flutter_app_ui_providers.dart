import 'package:riverpod/riverpod.dart';

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

/// A tick per console line, so the console repaints without the lines living in
/// the registry — a chatty app would rebuild every watcher once per line.
final flutterAppConsoleTickProvider = StreamProvider.family<int, String>((
  ref,
  appId,
) {
  // Watched, not read: a re-attach replaces the link, and the subscription has
  // to follow it. Registry changes are rare, so re-subscribing on one is free.
  ref.watch(attachedAppsProvider);
  final link = ref.read(attachedAppsProvider.notifier).linkFor(appId);
  if (link == null) return const Stream<int>.empty();
  var lines = 0;
  return link.logs.map((_) => ++lines);
});
