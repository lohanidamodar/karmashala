/// The quick-access pins every file browser shows, as the server keeps them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// [QuickAccessPins] over the data link: the copy the server keeps this
/// client told of, and the `quickAccess.*` requests that change it. A change
/// made anywhere — this window, the phone — arrives as `quickAccessChanged`
/// and is drawn by every browser listening.
class ServerQuickAccess extends ChangeNotifier implements QuickAccessPins {
  ServerQuickAccess(this._client) {
    _pins = _convert(_client.quickAccessPins);
    _changes = _client.quickAccessChanges.listen((pins) {
      _pins = _convert(pins);
      notifyListeners();
    });
  }

  final DataClient _client;
  late final StreamSubscription<List<QuickAccessPin>> _changes;
  late List<PinnedFolder> _pins;
  String? _unavailable;

  @override
  List<PinnedFolder> get pins => _pins;

  @override
  String? get unavailable => _unavailable;

  @override
  Future<void> pin(PinnedFolder folder) => _send(
    QuickAccessPinFolder(
      QuickAccessPin(
        environmentId: folder.environmentId,
        path: folder.path,
        label: folder.label,
      ),
    ),
  );

  @override
  Future<void> unpin(PinnedFolder folder) => _send(
    QuickAccessUnpin(environmentId: folder.environmentId, path: folder.path),
  );

  @override
  Future<void> rename(PinnedFolder folder, String? label) => _send(
    QuickAccessRename(
      environmentId: folder.environmentId,
      path: folder.path,
      label: label,
    ),
  );

  /// Sends [request] and draws its answer at once, ahead of the change the
  /// server tells every client.
  Future<void> _send(QuickAccessRequest request) async {
    try {
      final reply = await _client.send(request);
      _pins = _convert(reply.value);
      notifyListeners();
    } on DataRefused catch (refusal) {
      if (refusal.message.contains('no data request is called')) {
        _unavailable =
            'The server is older than this app and keeps no quick access '
            'yet. Restart it to pin folders.';
        notifyListeners();
        throw StateError(_unavailable!);
      }
      throw StateError(refusal.message);
    }
  }

  static List<PinnedFolder> _convert(List<QuickAccessPin> pins) => [
    for (final pin in pins)
      PinnedFolder(
        environmentId: pin.environmentId,
        path: pin.path,
        label: pin.label,
      ),
  ];

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }
}

/// The pins for the server this window uses; rebuilt with its data client.
final quickAccessPinsProvider = Provider<ServerQuickAccess>((ref) {
  final pins = ServerQuickAccess(ref.watch(dataClientProvider));
  ref.onDispose(pins.dispose);
  return pins;
});
