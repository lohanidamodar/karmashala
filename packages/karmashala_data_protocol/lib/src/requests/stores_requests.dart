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
      StoresRefreshApp.name => StoresRefreshApp(
        store: StoreKind.parse(args.string('store')),
        id: args.string('id'),
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
      StoreAppsLink.name => StoreAppsLink(
        appStoreId: args.string('appStoreId'),
        packageName: args.string('packageName'),
      ),
      StoreAppsUnlink.name => StoreAppsUnlink(
        appStoreId: args.string('appStoreId'),
        packageName: args.string('packageName'),
      ),
      StoresSeen.name => StoresSeen(args.strings('appKeys')),
      StoresScheduleSet.name => StoresScheduleSet(
        Duration(
          minutes:
              args.optionalInt('everyMinutes') ??
              (throw const DataRefused.invalid(
                'stores.schedule.set: "everyMinutes" must be a whole number',
              )),
        ),
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

/// Reads one app again, now, and answers when done: the retry for an app
/// whose read failed. Refused for an app the server does not hold.
final class StoresRefreshApp extends _StoresViewRequest {
  const StoresRefreshApp({required this.store, required this.id});

  static const String name = 'stores.refresh.app';

  final StoreKind store;

  /// The app's [StoreApp.id] on [store].
  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'store': store.name, 'id': id};
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

/// Combines an App Store app and a Google Play app into one, whatever their
/// bundle id and package name: they show and are read as one app from then
/// on. Each must be among the apps the server holds. Either one already
/// combined by hand leaves its old pair. Not a credential: a phone may ask.
final class StoreAppsLink extends _StoresViewRequest {
  const StoreAppsLink({required this.appStoreId, required this.packageName});

  static const String name = 'stores.link';

  /// The App Store app's numeric id.
  final String appStoreId;

  /// The Play app's package name.
  final String packageName;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'appStoreId': appStoreId,
    'packageName': packageName,
  };
}

/// Separates a pair [StoreAppsLink] combined; each app then joins whatever
/// its own id matches, or stands alone. Refused when the two are not a pair.
final class StoreAppsUnlink extends _StoresViewRequest {
  const StoreAppsUnlink({required this.appStoreId, required this.packageName});

  static const String name = 'stores.unlink';

  final String appStoreId;
  final String packageName;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'appStoreId': appStoreId,
    'packageName': packageName,
  };
}

/// Apps [appKeys] (each a `StoreApp.key`) were opened: what changed about
/// them is seen, here and in the inbox. Not a credential: a phone may ask.
final class StoresSeen extends _StoresViewRequest {
  const StoresSeen(this.appKeys);

  static const String name = 'stores.seen';

  final List<String> appKeys;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'appKeys': appKeys};
}

/// How often the server reads the stores on its own; [every] is one of
/// `StoreRefreshSchedule.choices`, [Duration.zero] for never.
final class StoresScheduleSet extends _StoresViewRequest {
  const StoresScheduleSet(this.every);

  static const String name = 'stores.schedule.set';

  final Duration every;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'everyMinutes': every.inMinutes};
}
