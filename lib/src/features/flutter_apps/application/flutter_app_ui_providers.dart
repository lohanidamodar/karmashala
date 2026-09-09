import 'package:riverpod/riverpod.dart';

import 'attached_apps.dart';

/// Which attached app the pane is about, or `null` for "no explicit choice".
///
/// A per-surface selection rather than one global "the app": several apps run
/// side by side by design, and the panel showing one of them must not decide
/// which one an MCP call means. Next to the registry on purpose — the same
/// reasoning `selectedDeviceSerialProvider` is written with, and the same fault
/// it exists to prevent.
class SelectedFlutterAppId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

final selectedFlutterAppIdProvider =
    NotifierProvider<SelectedFlutterAppId, String?>(
      SelectedFlutterAppId.new,
    );

/// The app the pane is describing: the explicit choice, or the only attached
/// one when there is exactly one.
///
/// Derived, so the pane and the actions on it cannot hold two opinions about
/// which app is on screen.
final paneFlutterAppIdProvider = Provider<String?>((ref) {
  final registry = ref.watch(attachedAppsProvider);
  final chosen = ref.watch(selectedFlutterAppIdProvider);
  if (chosen != null && registry.byId(chosen) != null) return chosen;
  return registry.onlyAttached?.id ??
      (registry.apps.length == 1 ? registry.apps.single.id : null);
});

/// A tick per console line, so the console repaints without the lines
/// themselves living in the registry's state.
///
/// Keeping the buffer out of the notifier's state is the point: a chatty app
/// writes several lines a frame, and putting them in `FlutterAppRegistry` would
/// rebuild every widget watching the registry — the status row, the app list,
/// the action bar — for each one.
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
