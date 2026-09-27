part of '../data_change.dart';

// The server's browser (slice 3d), told to every desktop client.

DataChange? _browserChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'browserStateChanged' => BrowserStateChanged(
        BrowserState.fromJson(_row(json)),
      ),
      _ => null,
    };

/// The server's browser, as it now stands.
final class BrowserStateChanged extends RunsChange {
  const BrowserStateChanged(this.state);

  final BrowserState state;

  @override
  Map<String, Object?> toJson() => {
    'change': 'browserStateChanged',
    'row': state.toJson(),
  };
}
