import 'dart:async';

import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:riverpod/riverpod.dart';

import '../data/flutter_data.dart';

/// The Flutter apps the server is attached to, followed from its changes.
/// Finding, attaching and driving them is the server's (slice 3d); this only
/// shows them and asks.
class AttachedApps extends Notifier<FlutterAppRegistry> {
  @override
  FlutterAppRegistry build() {
    final data = ref.watch(flutterDataProvider);
    final changes = data.changes.listen((_) => state = data.registry);
    ref.onDispose(changes.cancel);
    return data.registry;
  }

  FlutterData get _data => ref.read(flutterDataProvider);

  /// Has the server look for running apps now.
  Future<void> look() async {
    state = await _data.look();
  }

  /// Attaches the server to an address somebody typed.
  Future<AttachedApp> attach(String rawUri) => _data.attach(rawUri);

  Future<void> hotReload(String id) => _data.reload(id);

  Future<void> hotRestart(String id) => _data.reload(id, full: true);

  Future<void> detach(String id) => _data.detach(id);

  Future<void> forget(String id) => _data.forget(id);

  /// Waits for a tap in app [id]; the picked widget as an agent reads it.
  Future<String> pickWidget(String id) => _data.pickWidget(id);

  /// How an app becomes visible to the server.
  String get attachHint =>
      'A run the Karmashala server started, a "flutter run" started anywhere '
      'else on the server\'s machine, and an app on an Android device '
      'connected to this desktop are all found on their own. A run anywhere '
      'else still needs its address attached by hand.';
}

final attachedAppsProvider = NotifierProvider<AttachedApps, FlutterAppRegistry>(
  AttachedApps.new,
);
