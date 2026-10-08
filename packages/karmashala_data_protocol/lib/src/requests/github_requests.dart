part of '../data_request.dart';

// GitHub access (Settings → Source control → GitHub) and agents' secret
// requests. A token or a secret travels client → server only, in
// `github.token.save` and `secrets.provide`; no answer or change carries one.

DataRequest<Object?>? _githubRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      GithubAccessRead.name => const GithubAccessRead(),
      GithubTokenSave.name => GithubTokenSave(
        args.string('host'),
        args.string('token'),
      ),
      GithubTokenClear.name => GithubTokenClear(args.string('host')),
      GithubTokenTest.name => GithubTokenTest(args.string('host')),
      GithubHostChoose.name => GithubHostChoose(
        args.string('host'),
        account: args.optionalString('account'),
        off: args.boolean('off', orElse: false),
      ),
      SecretRequestsRead.name => const SecretRequestsRead(),
      SecretProvide.name => SecretProvide(
        args.string('id'),
        args.string('value'),
      ),
      SecretDecline.name => SecretDecline(args.string('id')),
      _ => null,
    };

/// Work on the server's GitHub access; answered when done.
sealed class GithubAccessRequest<R> extends DataRequest<R> {
  const GithubAccessRequest();
}

sealed class _GithubStatusRequest
    extends GithubAccessRequest<GithubAccessStatus> {
  const _GithubStatusRequest();

  @override
  Object? resultToJson(GithubAccessStatus result) => result.toJson();

  @override
  GithubAccessStatus resultFromJson(Object? json) =>
      _decode(kind, () => GithubAccessStatus.fromJson(_object(json, kind)));
}

/// Where each host's access comes from, the saved tokens and gh's accounts.
final class GithubAccessRead extends _GithubStatusRequest {
  const GithubAccessRead();

  static const String name = 'github.access';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};
}

/// Saves [token] for [host] in the server's secret store, replacing any.
final class GithubTokenSave extends _GithubStatusRequest {
  const GithubTokenSave(this.host, this.token);

  static const String name = 'github.token.save';

  final String host;
  final String token;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'host': host, 'token': token};
}

/// Forgets the token saved for [host].
final class GithubTokenClear extends _GithubStatusRequest {
  const GithubTokenClear(this.host);

  static const String name = 'github.token.clear';

  final String host;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'host': host};
}

/// Asks GitHub's `GET /user` who [host]'s token is: the saved one when there
/// is one, the token in use otherwise.
final class GithubTokenTest extends GithubAccessRequest<GithubTokenCheck> {
  const GithubTokenTest(this.host);

  static const String name = 'github.token.test';

  final String host;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'host': host};

  @override
  Object? resultToJson(GithubTokenCheck result) => result.toJson();

  @override
  GithubTokenCheck resultFromJson(Object? json) =>
      _decode(kind, () => GithubTokenCheck.fromJson(_object(json, kind)));
}

/// Picks gh's [account] for [host] (null follows gh's active one), or turns
/// the host [off].
final class GithubHostChoose extends _GithubStatusRequest {
  const GithubHostChoose(this.host, {this.account, this.off = false});

  static const String name = 'github.host.choose';

  final String host;
  final String? account;
  final bool off;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'host': host,
    'account': ?account,
    'off': off,
  };
}

/// Answering agents' requests for a secret; answered when done.
sealed class SecretRequestWork<R> extends DataRequest<R> {
  const SecretRequestWork();
}

/// The requests waiting for the owner.
final class SecretRequestsRead extends SecretRequestWork<List<SecretRequest>> {
  const SecretRequestsRead();

  static const String name = 'secrets.pending';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<SecretRequest> result) => [
    for (final request in result) request.toJson(),
  ];

  @override
  List<SecretRequest> resultFromJson(Object? json) => _decode(
    kind,
    () => [
      for (final item in _objects(json, kind)) SecretRequest.fromJson(item),
    ],
  );
}

/// Saves [value] for request [id]; the agent is given a reference, never it.
final class SecretProvide extends SecretRequestWork<DataAck> {
  const SecretProvide(this.id, this.value);

  static const String name = 'secrets.provide';

  final String id;
  final String value;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'value': value};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Declines request [id]; the agent is told so.
final class SecretDecline extends SecretRequestWork<DataAck> {
  const SecretDecline(this.id);

  static const String name = 'secrets.decline';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
