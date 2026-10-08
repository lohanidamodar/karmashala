part of '../data_change.dart';

// Agents' requests for a secret, as every client may know them: the label and
// the reason, never a value.

DataChange? _githubChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'secretRequestsChanged' => SecretRequestsChanged([
        for (final item in json['requests']! as List)
          SecretRequest.fromJson((item as Map).cast<String, Object?>()),
      ]),
      _ => null,
    };

/// The secret requests waiting for the owner, whole — told when one is made
/// or answered, and to a client that subscribes.
final class SecretRequestsChanged extends DataChange {
  const SecretRequestsChanged(this.requests);

  final List<SecretRequest> requests;

  @override
  Map<String, Object?> toJson() => {
    'change': 'secretRequestsChanged',
    'requests': [for (final request in requests) request.toJson()],
  };
}
