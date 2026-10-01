/// The app stores as a client may know them: what each store said about each
/// app, and which credentials the server holds — never the credentials
/// themselves. The server keeps those in its own vault and uses them.
library;

import 'package:store_console/store_console.dart';

/// The App Store Connect key the server holds, without its private key.
final class AppleKeySummary {
  const AppleKeySummary({
    required this.keyId,
    required this.issuerId,
    required this.importedAt,
    this.vendorNumber,
  });

  final String keyId;
  final String issuerId;
  final String? vendorNumber;
  final DateTime importedAt;

  Map<String, Object?> toJson() => {
    'keyId': keyId,
    'issuerId': issuerId,
    'vendorNumber': vendorNumber,
    'importedAt': importedAt.toUtc().toIso8601String(),
  };

  factory AppleKeySummary.fromJson(Map<String, Object?> json) =>
      AppleKeySummary(
        keyId: json['keyId']! as String,
        issuerId: json['issuerId']! as String,
        vendorNumber: json['vendorNumber'] as String?,
        importedAt: DateTime.parse(json['importedAt']! as String),
      );
}

/// The Play service account the server holds, without its key.
final class PlayAccountSummary {
  const PlayAccountSummary({
    required this.importedAt,
    this.clientEmail,
    this.reportsBucket,
    this.packageNames = const [],
  });

  final String? clientEmail;
  final String? reportsBucket;
  final List<String> packageNames;
  final DateTime importedAt;

  Map<String, Object?> toJson() => {
    'clientEmail': clientEmail,
    'reportsBucket': reportsBucket,
    'packageNames': packageNames,
    'importedAt': importedAt.toUtc().toIso8601String(),
  };

  factory PlayAccountSummary.fromJson(Map<String, Object?> json) =>
      PlayAccountSummary(
        clientEmail: json['clientEmail'] as String?,
        reportsBucket: json['reportsBucket'] as String?,
        packageNames: ((json['packageNames'] as List?) ?? const [])
            .cast<String>(),
        importedAt: DateTime.parse(json['importedAt']! as String),
      );
}

/// An app's icon as the server keeps it: fetched from the app's public store
/// page, at most daily, and written to the server's own disk. A client that
/// cannot read that disk brings [path] over with `files.read`, spelled for
/// the server's host environment.
final class StoreAppIcon {
  const StoreAppIcon({required this.checkedAt, this.url, this.path});

  /// The public image it was fetched from; null when the app has no public
  /// store page (unpublished, a draft) — then there is no icon.
  final String? url;

  /// The copy on the server's disk, as the server's host spells it.
  final String? path;

  /// When the store was last asked.
  final DateTime checkedAt;

  Map<String, Object?> toJson() => {
    'url': url,
    'path': path,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };

  factory StoreAppIcon.fromJson(Map<String, Object?> json) => StoreAppIcon(
    url: json['url'] as String?,
    path: json['path'] as String?,
    checkedAt: DateTime.parse(json['checkedAt']! as String),
  );
}

/// Everything the Stores tab and an agent are shown, as the server holds it.
final class StoresView {
  const StoresView({
    this.apple,
    this.play,
    this.stores = const {},
    this.apps = const [],
    this.icons = const {},
    this.refreshedAt,
    this.refreshing = false,
  });

  final AppleKeySummary? apple;
  final PlayAccountSummary? play;

  /// What each connected store said when last asked for its apps; a store
  /// that failed says why. A store never asked is absent.
  final Map<StoreKind, Reading<List<StoreApp>>> stores;

  /// What was read about each app, as last read.
  final List<StoreAppSnapshot> apps;

  /// Each app's icon by [StoreApp.key]; an app never looked up is absent.
  final Map<String, StoreAppIcon> icons;

  /// When the stores were last read and at least one answered. Null when
  /// never.
  final DateTime? refreshedAt;

  /// Whether a read of the stores is under way.
  final bool refreshing;

  /// The stores the server holds a credential for.
  Set<StoreKind> get connected => {
    if (apple != null) StoreKind.appStore,
    if (play != null) StoreKind.googlePlay,
  };

  Map<String, Object?> toJson() => {
    'apple': apple?.toJson(),
    'play': play?.toJson(),
    'stores': {
      for (final MapEntry(:key, :value) in stores.entries)
        key.name: value.toJson(
          (apps) => [for (final app in apps) app.toJson()],
        ),
    },
    'apps': [for (final app in apps) app.toJson()],
    'icons': {
      for (final MapEntry(:key, :value) in icons.entries) key: value.toJson(),
    },
    'refreshedAt': refreshedAt?.toUtc().toIso8601String(),
    'refreshing': refreshing,
  };

  factory StoresView.fromJson(Map<String, Object?> json) {
    Map<String, Object?> map(Object? value) =>
        (value! as Map).cast<String, Object?>();
    final apple = json['apple'];
    final play = json['play'];
    final refreshedAt = json['refreshedAt'];
    return StoresView(
      apple: apple == null ? null : AppleKeySummary.fromJson(map(apple)),
      play: play == null ? null : PlayAccountSummary.fromJson(map(play)),
      stores: {
        for (final MapEntry(:key, :value)
            in ((json['stores'] as Map?) ?? const {}).entries)
          StoreKind.parse(key as String): Reading.fromJson(
            map(value),
            (encoded) => [
              for (final app in encoded! as List) StoreApp.fromJson(map(app)),
            ],
          ),
      },
      apps: [
        for (final app in (json['apps'] as List?) ?? const [])
          StoreAppSnapshot.fromJson(map(app)),
      ],
      // Absent from an older server's view.
      icons: {
        for (final MapEntry(:key, :value)
            in ((json['icons'] as Map?) ?? const {}).entries)
          key as String: StoreAppIcon.fromJson(map(value)),
      },
      refreshedAt: refreshedAt is String ? DateTime.parse(refreshedAt) : null,
      refreshing: json['refreshing'] as bool? ?? false,
    );
  }
}
