import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_store/database.dart';

/// The preference the app's settings live under; its `flutterSdkPaths` map
/// is the Flutter a person named per environment.
const String kSettingsPreferenceKey = 'settings.v1';

/// Where `flutter` is in each environment the server runs in, in memory only
/// (PATH moves). A hand-set path is read per call, and a changed one is
/// measured again.
class ServerFlutterSdk {
  ServerFlutterSdk({
    required AppDatabase database,
    this.runners = const CommandRunnerFactory(),
    DateTime Function()? clock,
  }) : _database = database,
       _now = clock ?? _utcNow;

  final AppDatabase _database;
  final CommandRunnerFactory runners;
  final DateTime Function() _now;
  final _held = <String, ({FlutterSdkReading reading, String? handSet})>{};

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// What was last read for [environmentId], however old, or null — "not
  /// looked", never "no Flutter".
  FlutterSdkReading? cached(String environmentId) =>
      _held[environmentId]?.reading;

  /// The Flutter a person named for [environmentId], or null.
  String? handSetFor(String environmentId) {
    final raw = _database.readMetadata(kSettingsPreferenceKey);
    if (raw == null) return null;
    try {
      final settings = jsonDecode(raw);
      if (settings is! Map) return null;
      final paths = settings['flutterSdkPaths'];
      if (paths is! Map) return null;
      final path = paths[environmentId];
      return path is String && path.trim().isNotEmpty ? path.trim() : null;
    } on FormatException {
      return null;
    }
  }

  /// Where `flutter` is in [environment], reusing a fresh reading unless
  /// [force] or the hand-set path moved.
  Future<FlutterSdkReading> readFor(
    ExecutionEnvironment environment, {
    bool force = false,
  }) async {
    final now = _now();
    final handSet = handSetFor(environment.id);
    final held = _held[environment.id];
    if (!force &&
        held != null &&
        held.handSet == handSet &&
        held.reading.isFreshAt(now)) {
      return held.reading;
    }
    final reading = await FlutterSdkService(
      runner: runners.forEnvironment(environment),
      environment: environment,
      handSetExecutable: handSet,
    ).read(now);
    _held[environment.id] = (reading: reading, handSet: handSet);
    return reading;
  }

  void forget(String environmentId) => _held.remove(environmentId);
}
