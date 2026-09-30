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
      _ => null,
    };

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
