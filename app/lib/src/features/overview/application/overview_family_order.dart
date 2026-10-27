import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import 'overview_prefs.dart';
import 'overview_providers.dart';
import 'overview_tree.dart';

/// The owner's hand order of each lane's families: root ids by lane key.
typedef OverviewFamilyOrder = Map<String, List<String>>;

/// **Where each family sits in its lane**, on this device: the order the
/// owner dragged them into, kept across restarts. A family nobody moved sits
/// by its start time.
class OverviewFamilyOrderController extends Notifier<OverviewFamilyOrder> {
  static final _log = AppLogger.named('overview.order');
  var _touched = false;

  @override
  OverviewFamilyOrder build() {
    unawaited(_load());
    return const {};
  }

  Future<File> _file() async => File(
    p.join(
      (await ref.read(overviewPrefsDirectoryProvider)()).path,
      'overview_family_order.json',
    ),
  );

  Future<void> _load() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      if (json is! Map) return;
      final kept = <String, List<String>>{
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is List)
            key: [for (final id in value) ?(id is String ? id : null)],
      };
      // A move made while the file was read wins over what it held.
      if (ref.mounted) state = {...kept, if (_touched) ...state};
    } on Object {
      // Nothing kept yet, or unreadable: every family by its start time.
    }
  }

  /// Moves [id] to [index] among [drawn], the lane's families as drawn now.
  void move(String laneKey, List<String> drawn, String id, int index) {
    if (!ref.mounted || !drawn.contains(id)) return;
    final next = [...drawn]..remove(id);
    next.insert(index.clamp(0, next.length), id);
    _touched = true;
    state = {...state, laneKey: next};
    unawaited(_write());
  }

  /// Moves [id] one place earlier (`step` -1) or later (1) in [drawn].
  void step(String laneKey, List<String> drawn, String id, int step) {
    final at = drawn.indexOf(id);
    if (at < 0) return;
    move(laneKey, drawn, id, at + step);
  }

  Future<void> _write() async {
    final order = state;
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(order), flush: true);
    } on Object catch (e) {
      _log.warning('Keeping the order of the families failed: $e');
    }
  }
}

final overviewFamilyOrderProvider =
    NotifierProvider<OverviewFamilyOrderController, OverviewFamilyOrder>(
      OverviewFamilyOrderController.new,
    );

/// The board as families, lane by lane, each in its fixed place.
final overviewForestProvider = Provider.autoDispose<OverviewForest>(
  (ref) => overviewForestOf(
    ref.watch(overviewBoardProvider),
    order: ref.watch(overviewFamilyOrderProvider),
    pinned: ref.watch(overviewPrefsProvider.select((p) => p.pinned)).toSet(),
  ),
);
