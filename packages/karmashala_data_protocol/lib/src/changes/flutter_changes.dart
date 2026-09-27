part of '../data_change.dart';

// What the server's Flutter work, builds and browser are doing (slice 3d),
// told to every desktop client.

DataChange? _flutterChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'flutterAppsChanged' => FlutterAppsChanged(
        flutterRegistryFromJson(_row(json)),
      ),
      'hostedRunChanged' => HostedRunChanged(HostedRun.fromJson(_row(json))),
      'hostedRunRemoved' => HostedRunRemoved(json['id']! as String),
      _ => null,
    };

/// A change to what the server runs and drives for a person to watch.
sealed class RunsChange extends DataChange {
  const RunsChange();
}

/// The apps the server is attached to, and when it last looked — whole: a
/// registry holds a handful of rows.
final class FlutterAppsChanged extends RunsChange {
  const FlutterAppsChanged(this.registry);

  final FlutterAppRegistry registry;

  @override
  Map<String, Object?> toJson() => {
    'change': 'flutterAppsChanged',
    'row': flutterRegistryToJson(registry),
  };
}

/// A run the server hosts, started or ended. A client opens a pane on a new
/// one (`HostedRun.paneId`).
final class HostedRunChanged extends RunsChange {
  const HostedRunChanged(this.run);

  final HostedRun run;

  @override
  Map<String, Object?> toJson() => {
    'change': 'hostedRunChanged',
    'row': run.toJson(),
  };
}

/// Run [runId] is forgotten (its record pruned).
final class HostedRunRemoved extends RunsChange {
  const HostedRunRemoved(this.runId);

  final String runId;

  @override
  Map<String, Object?> toJson() => {'change': 'hostedRunRemoved', 'id': runId};
}
