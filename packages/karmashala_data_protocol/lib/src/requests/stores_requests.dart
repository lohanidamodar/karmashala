part of '../data_request.dart';

// The app stores, read through the server. The server holds the credentials:
// a key or key file travels client → server in a set request only, and no
// answer, change, log line or `toString` carries one back. Answered when
// done — a refresh talks to the stores and can take a minute.

DataRequest<Object?>? _storesRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      StoresGet.name => const StoresGet(),
      StoresRefresh.name => StoresRefresh(
        maxAgeSeconds: args.optionalInt('maxAgeSeconds'),
      ),
      StoreAppleSet.name => StoreAppleSet(
        keyId: args.string('keyId'),
        issuerId: args.string('issuerId'),
        privateKeyPem: args.optionalString('privateKeyPem'),
        vendorNumber: args.optionalString('vendorNumber'),
      ),
      StorePlaySet.name => StorePlaySet(
        serviceAccountJson: args.optionalString('serviceAccountJson'),
        reportsBucket: args.optionalString('reportsBucket'),
        packageNames: args.strings('packageNames', orEmpty: true),
      ),
      StoreCredentialRemove.name => StoreCredentialRemove(
        StoreKind.parse(args.string('store')),
      ),
      _ => null,
    };

/// Work on the app stores; answered when done.
sealed class StoreRequest<R> extends DataRequest<R> {
  const StoreRequest();
}

abstract final class _StoresViewRequest extends StoreRequest<StoresView> {
  const _StoresViewRequest();

  @override
  Object? resultToJson(StoresView result) => result.toJson();

  @override
  StoresView resultFromJson(Object? json) =>
      _decode(kind, () => StoresView.fromJson(_object(json, kind)));
}

/// What the server holds now, without asking the stores.
final class StoresGet extends _StoresViewRequest {
  const StoresGet();

  static const String name = 'stores.get';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};
}

/// Reads every connected store again and answers when done. With
/// [maxAgeSeconds], a view younger than that is answered as it is. A refresh
/// already under way is joined, not doubled.
final class StoresRefresh extends _StoresViewRequest {
  const StoresRefresh({this.maxAgeSeconds});

  static const String name = 'stores.refresh';

  final int? maxAgeSeconds;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    if (maxAgeSeconds != null) 'maxAgeSeconds': maxAgeSeconds,
  };
}

/// Sets the App Store Connect key. A null [privateKeyPem] keeps the key file
/// already held and changes only the other fields; refused when none is held.
final class StoreAppleSet extends _StoresViewRequest {
  const StoreAppleSet({
    required this.keyId,
    required this.issuerId,
    this.privateKeyPem,
    this.vendorNumber,
  });

  static const String name = 'stores.apple.set';

  final String keyId;
  final String issuerId;
  final String? privateKeyPem;
  final String? vendorNumber;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'keyId': keyId,
    'issuerId': issuerId,
    if (privateKeyPem != null) 'privateKeyPem': privateKeyPem,
    if (vendorNumber != null) 'vendorNumber': vendorNumber,
  };
}

/// Sets the Play service account. A null [serviceAccountJson] keeps the key
/// already held and changes only the other fields; refused when none is held.
final class StorePlaySet extends _StoresViewRequest {
  const StorePlaySet({
    this.serviceAccountJson,
    this.reportsBucket,
    this.packageNames = const [],
  });

  static const String name = 'stores.play.set';

  final String? serviceAccountJson;
  final String? reportsBucket;
  final List<String> packageNames;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    if (serviceAccountJson != null) 'serviceAccountJson': serviceAccountJson,
    if (reportsBucket != null) 'reportsBucket': reportsBucket,
    'packageNames': packageNames,
  };
}

/// Forgets [store]'s credential and what was read with it.
final class StoreCredentialRemove extends _StoresViewRequest {
  const StoreCredentialRemove(this.store);

  static const String name = 'stores.credential.remove';

  final StoreKind store;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'store': store.name};
}
