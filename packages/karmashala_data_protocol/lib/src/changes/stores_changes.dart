part of '../data_change.dart';

// The app stores as the server holds them. Never a credential.

DataChange? _storesChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'storesChanged' => StoresChanged(
        StoresView.fromJson((json['view']! as Map).cast<String, Object?>()),
      ),
      'storesProgress' => StoresProgress(
        done: json['done']! as int,
        total: json['total']! as int,
      ),
      'storeAppChanged' => StoreAppChanged(
        app: StoreApp.fromJson(_storesMap(json['app'])),
        read: json['read'] == null
            ? null
            : StoreAppRead.fromJson(_storesMap(json['read'])),
        snapshot: json['snapshot'] == null
            ? null
            : StoreAppSnapshot.fromJson(_storesMap(json['snapshot'])),
        icon: json['icon'] == null
            ? null
            : StoreAppIcon.fromJson(_storesMap(json['icon'])),
      ),
      'storeChangesNoticed' => StoreChangesNoticed([
        for (final held in (json['changes'] as List?) ?? const [])
          StoreAppChanges.fromJson(_storesMap(held)),
      ]),
      _ => null,
    };

Map<String, Object?> _storesMap(Object? value) =>
    (value! as Map).cast<String, Object?>();

/// One app's place in a read, and what was read about it when it lands: told
/// as each app moves, so a client fills its rows in one at a time without the
/// whole view crossing again.
final class StoreAppChanged extends DataChange {
  const StoreAppChanged({
    required this.app,
    this.read,
    this.snapshot,
    this.icon,
  });

  final StoreApp app;

  /// Null when the app is as last read, with nothing under way.
  final StoreAppRead? read;

  /// What was just read; null when only [read] moved.
  final StoreAppSnapshot? snapshot;

  /// The icon just looked up; null when it was not.
  final StoreAppIcon? icon;

  @override
  Map<String, Object?> toJson() => {
    'change': 'storeAppChanged',
    'app': app.toJson(),
    if (read case final read?) 'read': read.toJson(),
    if (snapshot case final snapshot?) 'snapshot': snapshot.toJson(),
    if (icon case final icon?) 'icon': icon.toJson(),
  };
}

extension StoresViewApps on StoresView {
  /// This view with [change] applied to its app.
  StoresView withApp(StoreAppChanged change) {
    final key = change.app.key;
    final snapshot = change.snapshot;
    final icon = change.icon;
    final read = change.read;
    return StoresView(
      apple: apple,
      play: play,
      stores: stores,
      apps: snapshot == null
          ? apps
          : [
              for (final held in apps)
                if (held.app.key != key) held,
              snapshot,
            ],
      icons: icon == null ? icons : {...icons, key: icon},
      links: links,
      refreshedAt: refreshedAt,
      refreshing: refreshing,
      reads: {
        for (final MapEntry(key: other, :value) in reads.entries)
          if (other != key) other: value,
        key: ?read,
      },
      changes: changes,
      schedule: schedule,
    );
  }
}

/// The whole view as it now stands — told when a refresh starts and ends,
/// when a credential changes, and to a client that subscribes.
final class StoresChanged extends DataChange {
  const StoresChanged(this.view);

  final StoresView view;

  @override
  Map<String, Object?> toJson() => {
    'change': 'storesChanged',
    'view': view.toJson(),
  };
}

/// How far a refresh under way has got: [done] apps of [total] read. Small
/// on purpose, since it is told once per app.
final class StoresProgress extends DataChange {
  const StoresProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Map<String, Object?> toJson() => {
    'change': 'storesProgress',
    'done': done,
    'total': total,
  };
}

/// What a read of the stores found changed, told once as it finishes: for a
/// client's notification. The view's own [StoresView.changes] keeps it after.
final class StoreChangesNoticed extends DataChange {
  const StoreChangesNoticed(this.changes);

  /// One per app that changed.
  final List<StoreAppChanges> changes;

  @override
  Map<String, Object?> toJson() => {
    'change': 'storeChangesNoticed',
    'changes': [for (final held in changes) held.toJson()],
  };
}
