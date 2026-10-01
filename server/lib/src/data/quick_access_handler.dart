import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';

/// The folders pinned to every file browser's quick-access column, at the
/// server: one ordered list for every client, so a folder pinned on the phone
/// is in the desktop's picker too. Kept as one JSON row of `app_metadata`
/// ([QuickAccessKeys.pins]); each write is told whole (`quickAccessChanged`).
class QuickAccessHandler {
  QuickAccessHandler(this._db);

  final AppDatabase _db;

  /// Every pin, in order. A row that does not read is an empty list rather
  /// than a refusal: the column is a convenience, never a reason to fail.
  List<QuickAccessPin> list() {
    final stored = _db.readMetadata(QuickAccessKeys.pins);
    if (stored == null || stored.isEmpty) return const [];
    try {
      return [
        for (final item in jsonDecode(stored) as List)
          QuickAccessPin.fromJson((item as Map).cast<String, Object?>()),
      ];
    } on Object {
      return const [];
    }
  }

  /// What a subscribing client is greeted with: nothing while nothing is
  /// pinned, which a client takes a new link to mean.
  List<DataChange> greeting() {
    final pins = list();
    return pins.isEmpty ? const [] : [QuickAccessChanged(pins)];
  }

  List<QuickAccessPin> handle(
    QuickAccessRequest request,
    List<DataChange> changes,
  ) => switch (request) {
    QuickAccessList() => list(),
    QuickAccessPinFolder(:final pin) => _pin(pin, changes),
    QuickAccessUnpin(:final environmentId, :final path) => _write([
      for (final pin in list())
        if (!pin.sameFolder(_at(environmentId, path))) pin,
    ], changes),
    QuickAccessRename(:final environmentId, :final path, :final label) =>
      _rename(_at(environmentId, path), label, changes),
  };

  List<QuickAccessPin> _pin(QuickAccessPin pin, List<DataChange> changes) {
    _check(pin.environmentId, pin.path);
    final label = _label(pin.label);
    final pins = list();
    final index = pins.indexWhere(pin.sameFolder);
    if (index >= 0) {
      if (label == null) return pins;
      return _write([...pins]..[index] = pins[index].withLabel(label), changes);
    }
    if (pins.length >= QuickAccessPin.maxPins) {
      throw const DataRefused.invalid(
        'quick access holds ${QuickAccessPin.maxPins} folders; unpin one '
        'first',
      );
    }
    return _write([
      ...pins,
      QuickAccessPin(
        environmentId: pin.environmentId,
        path: pin.path.trim(),
        label: label,
      ),
    ], changes);
  }

  List<QuickAccessPin> _rename(
    QuickAccessPin at,
    String? label,
    List<DataChange> changes,
  ) {
    final pins = list();
    final index = pins.indexWhere(at.sameFolder);
    if (index < 0) {
      throw DataRefused.notFound('${at.path} is not in quick access');
    }
    return _write(
      [...pins]..[index] = pins[index].withLabel(_label(label)),
      changes,
    );
  }

  List<QuickAccessPin> _write(
    List<QuickAccessPin> pins,
    List<DataChange> changes,
  ) {
    _db.writeMetadata(
      QuickAccessKeys.pins,
      jsonEncode([for (final pin in pins) pin.toJson()]),
    );
    changes.add(QuickAccessChanged(List.unmodifiable(pins)));
    return pins;
  }

  static QuickAccessPin _at(String environmentId, String path) =>
      QuickAccessPin(environmentId: environmentId, path: path);

  /// A blank label is the folder's own name again.
  static String? _label(String? label) {
    final trimmed = label?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length > QuickAccessPin.maxLabelLength) {
      throw const DataRefused.invalid(
        'a quick-access name is at most ${QuickAccessPin.maxLabelLength} '
        'characters',
      );
    }
    return trimmed;
  }

  /// An absolute path in a named environment: a drive or a share on Windows,
  /// a root on POSIX. A relative one would mean a different folder to every
  /// browser that resolved it.
  static void _check(String environmentId, String path) {
    if (environmentId.trim().isEmpty) {
      throw const DataRefused.invalid('a pinned folder needs an environment');
    }
    final trimmed = path.trim();
    if (trimmed.length > QuickAccessPin.maxPathLength) {
      throw const DataRefused.invalid('that path is too long to pin');
    }
    final absolute =
        trimmed.startsWith('/') ||
        trimmed.startsWith(r'\\') ||
        RegExp(r'^[A-Za-z]:[\\/]?$|^[A-Za-z]:[\\/]').hasMatch(trimmed);
    if (!absolute) {
      throw DataRefused.invalid('"$path" is not a full path; pin a folder');
    }
  }
}
