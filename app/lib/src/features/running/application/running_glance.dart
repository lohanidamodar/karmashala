import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'running_providers.dart';

/// One listening server, as the dashboard's glance names it.
@immutable
class RunningGlanceServer {
  const RunningGlanceServer({required this.label, required this.port});

  /// The pane's title or the process name; null when neither is known.
  final String? label;
  final int port;

  /// "vite :5173".
  String get words => label == null ? ':$port' : '$label :$port';
}

/// What the Running tab would show, in brief: how many servers listen and
/// the newest of them — first seen most recently by this app. Null
/// [servers] until the first read, which is "not recorded", not zero.
@immutable
class RunningGlance {
  const RunningGlance({
    this.servers,
    this.newest,
    this.loading = false,
    this.error,
  });

  final int? servers;
  final RunningGlanceServer? newest;
  final bool loading;
  final String? error;
}

/// When each listening port was first seen, so "newest" means newest to
/// this app: a reading carries no start times.
class _FirstSeen {
  final _at = <String, DateTime>{};

  DateTime of(String key, DateTime now) => _at.putIfAbsent(key, () => now);

  void keepOnly(Set<String> keys) =>
      _at.removeWhere((k, _) => !keys.contains(k));
}

final _firstSeenProvider = Provider<_FirstSeen>((ref) => _FirstSeen());

/// The Running glance, from the Running tab's own reading.
final runningGlanceProvider = Provider<RunningGlance>((ref) {
  final snapshot = ref.watch(runningProvider);
  final reading = snapshot.reading;
  if (reading == null) {
    return RunningGlance(loading: snapshot.loading, error: snapshot.error);
  }
  final firstSeen = ref.read(_firstSeenProvider);
  final now = ref.read(clockProvider).nowUtc();
  final servers = <String, (RunningGlanceServer, DateTime)>{};
  for (final process in reading.processes) {
    if (process.pid == reading.serverPid) continue;
    for (final port in process.ports) {
      final key = '${process.pidMachine ?? ''}:${port.port}';
      if (servers.containsKey(key)) continue;
      servers[key] = (
        RunningGlanceServer(label: _labelOf(process), port: port.port),
        firstSeen.of(key, now),
      );
    }
  }
  firstSeen.keepOnly(servers.keys.toSet());
  RunningGlanceServer? newest;
  DateTime? newestAt;
  for (final (server, at) in servers.values) {
    if (newestAt == null || at.isAfter(newestAt)) {
      newest = server;
      newestAt = at;
    }
  }
  return RunningGlance(
    servers: servers.length,
    newest: newest,
    loading: snapshot.loading,
    error: snapshot.error,
  );
});

String? _labelOf(RunningProcess process) {
  final title = process.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  final name = process.name?.trim();
  return name == null || name.isEmpty ? null : name;
}
