/// The relays this desktop runs on its own SSH hosts: which boxes, where each
/// answers, and whether remote access serves through it. Beside the local and
/// hosted switches in `relay_prefs.dart`, and independent of both.
library;

import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';

/// Where the list lives in the `app_metadata` key/value table.
const String kSshRelaysMetadataKey = 'remote.ssh_relays.v1';

/// One SSH host used as a relay.
class SshRelayEntry {
  const SshRelayEntry({
    required this.hostId,
    required this.hostName,
    required this.port,
    required this.url,
    this.enabled = true,
  });

  final String hostId;

  /// The host's name when the relay was set up — a label for a device row
  /// whose host has since been removed, never a lookup key.
  final String hostName;

  final int port;

  /// `ws://<address>:<port>/k/<token>`. **Holds the relay's access token**: it
  /// is stored beside the device keys and shown nowhere — see [display].
  final Uri url;

  /// Whether remote access serves through it. Off after "Stop": the box is
  /// remembered, nothing listens there.
  final bool enabled;

  /// What a person may see: where it is, without the token that lets anybody
  /// use it.
  String get display => redactRelayUrl(url);

  SshRelayEntry copyWith({
    Uri? url,
    int? port,
    String? hostName,
    bool? enabled,
  }) => SshRelayEntry(
    hostId: hostId,
    hostName: hostName ?? this.hostName,
    port: port ?? this.port,
    url: url ?? this.url,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'hostId': hostId,
    'hostName': hostName,
    'port': port,
    'url': url.toString(),
    'enabled': enabled,
  };

  static SshRelayEntry? tryFromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final hostId = json['hostId'];
    final port = json['port'];
    final url = json['url'];
    if (hostId is! String || port is! int || url is! String) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) return null;
    final name = json['hostName'];
    return SshRelayEntry(
      hostId: hostId,
      hostName: name is String && name.isNotEmpty ? name : parsed.host,
      port: port,
      url: parsed,
      enabled: json['enabled'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SshRelayEntry &&
      other.hostId == hostId &&
      other.hostName == hostName &&
      other.port == port &&
      other.url == url &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(hostId, hostName, port, url, enabled);

  /// Never the URL: it would put the token in whatever printed this.
  @override
  String toString() => 'SshRelayEntry($hostId, $display, enabled: $enabled)';
}

/// A relay URL with its path dropped — `ws://box:8787`. The path is where a
/// box relay keeps its access token, so this is the only form fit for a
/// screen or a log.
String redactRelayUrl(Uri url) =>
    '${url.scheme}://${url.host}${url.hasPort ? ':${url.port}' : ''}';

class SshRelaysController extends Notifier<List<SshRelayEntry>> {
  @override
  List<SshRelayEntry> build() => readFrom(ref.watch(databaseProvider));

  /// What a fresh launch loads. A garbled entry costs itself and nothing else.
  static List<SshRelayEntry> readFrom(AppDatabase db) {
    final raw = db.readMetadata(kSshRelaysMetadataKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final byHost = <String, SshRelayEntry>{};
      for (final item in decoded) {
        final entry = SshRelayEntry.tryFromJson(item);
        if (entry != null) byHost[entry.hostId] = entry;
      }
      return List.unmodifiable(byHost.values);
    } on FormatException {
      return const [];
    }
  }

  SshRelayEntry? entryFor(String hostId) {
    for (final entry in state) {
      if (entry.hostId == hostId) return entry;
    }
    return null;
  }

  /// Adds the box, or replaces what was known about it. One relay per host.
  void put(SshRelayEntry entry) => _save([
    for (final existing in state)
      if (existing.hostId != entry.hostId) existing,
    entry,
  ]);

  void setEnabled(String hostId, bool enabled) => _save([
    for (final existing in state)
      existing.hostId == hostId
          ? existing.copyWith(enabled: enabled)
          : existing,
  ]);

  void remove(String hostId) => _save([
    for (final existing in state)
      if (existing.hostId != hostId) existing,
  ]);

  void _save(List<SshRelayEntry> entries) {
    state = List.unmodifiable(entries);
    ref
        .read(databaseProvider)
        .writeMetadata(
          kSshRelaysMetadataKey,
          jsonEncode([for (final entry in entries) entry.toJson()]),
        );
  }
}

final sshRelaysProvider =
    NotifierProvider<SshRelaysController, List<SshRelayEntry>>(
      SshRelaysController.new,
    );

/// The URLs remote access serves through right now, in the order they were
/// added.
final activeSshRelayUrlsProvider = Provider<List<Uri>>(
  (ref) => [
    for (final entry in ref.watch(sshRelaysProvider))
      if (entry.enabled) entry.url,
  ],
);
