part of '../data_request.dart';

// Which desktop client a person is using (slice 5b): what the server asks a
// window to show ([ClientIntent]) goes to the client that last said a person
// acted in it, or to the only one connected.

DataRequest<Object?>? _intentsRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      ClientActive.name => ClientActive(
        focusedPaneId: args.optionalString('focusedPaneId'),
      ),
      _ => null,
    };

/// A person just used this client's window (a key, a click), and
/// [focusedPaneId] is the pane in front of them. Sent at most every few
/// seconds; nothing is told of it.
final class ClientActive extends DataRequest<DataAck> {
  const ClientActive({this.focusedPaneId});

  static const String name = 'client.active';

  final String? focusedPaneId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'focusedPaneId': ?focusedPaneId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
