import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show immutable, listEquals, setEquals, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import 'overview_prefs.dart';

/// How this device lays out the dashboard's glances: their order, which are
/// hidden, which are folded to their title, and whether the area is folded.
@immutable
class GlancePrefs {
  const GlancePrefs({
    this.order = const [],
    this.hidden = const {},
    this.collapsed = const {},
    this.areaCollapsed = false,
  });

  /// Glance ids in the order placed; one not named keeps its registry place
  /// after these.
  final List<String> order;
  final Set<String> hidden;
  final Set<String> collapsed;
  final bool areaCollapsed;

  GlancePrefs copyWith({
    List<String>? order,
    Set<String>? hidden,
    Set<String>? collapsed,
    bool? areaCollapsed,
  }) => GlancePrefs(
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    collapsed: collapsed ?? this.collapsed,
    areaCollapsed: areaCollapsed ?? this.areaCollapsed,
  );

  Map<String, Object?> toJson() => {
    if (order.isNotEmpty) 'order': order,
    if (hidden.isNotEmpty) 'hidden': hidden.toList(),
    if (collapsed.isNotEmpty) 'collapsed': collapsed.toList(),
    if (areaCollapsed) 'areaCollapsed': true,
  };

  static GlancePrefs fromJson(Object? json) {
    if (json is! Map) return const GlancePrefs();
    List<String> strings(Object? value) =>
        value is List ? value.whereType<String>().toList() : const [];
    return GlancePrefs(
      order: strings(json['order']).toSet().toList(),
      hidden: strings(json['hidden']).toSet(),
      collapsed: strings(json['collapsed']).toSet(),
      areaCollapsed: json['areaCollapsed'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlancePrefs &&
      listEquals(other.order, order) &&
      setEquals(other.hidden, hidden) &&
      setEquals(other.collapsed, collapsed) &&
      other.areaCollapsed == areaCollapsed;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(order),
    Object.hashAllUnordered(hidden),
    Object.hashAllUnordered(collapsed),
    areaCollapsed,
  );
}

/// [ids], the registry's order, as [prefs] places them: the placed ones
/// first in their order, then the rest as registered. Hidden ones included.
List<String> arrangedGlanceIds(List<String> ids, GlancePrefs prefs) {
  final known = ids.toSet();
  return [
    for (final id in prefs.order)
      if (known.contains(id)) id,
    for (final id in ids)
      if (!prefs.order.contains(id)) id,
  ];
}

class GlancePrefsController extends Notifier<GlancePrefs> {
  static final _log = AppLogger.named('overview.glances');
  var _touched = false;

  @override
  GlancePrefs build() {
    unawaited(_load());
    return const GlancePrefs();
  }

  Future<File> _file() async => File(
    p.join(
      (await ref.read(overviewPrefsDirectoryProvider)()).path,
      'overview_glances.json',
    ),
  );

  Future<void> _load() async {
    try {
      final kept = GlancePrefs.fromJson(
        jsonDecode(await (await _file()).readAsString()),
      );
      if (ref.mounted && !_touched) state = kept;
    } on Object {
      // Nothing kept yet, or unreadable: every glance shows, as registered.
    }
  }

  void setHidden(String id, bool hidden) {
    final next = {...state.hidden};
    if (hidden ? next.add(id) : next.remove(id)) {
      _set(state.copyWith(hidden: next));
    }
  }

  void toggleCollapsed(String id) {
    final next = {...state.collapsed};
    if (!next.remove(id)) next.add(id);
    _set(state.copyWith(collapsed: next));
  }

  void setAreaCollapsed(bool collapsed) {
    if (state.areaCollapsed != collapsed) {
      _set(state.copyWith(areaCollapsed: collapsed));
    }
  }

  /// Moves [id] [by] places among the shown glances of [ids] (the registry's
  /// order); hidden ones keep their place.
  void move(String id, int by, {required List<String> ids}) {
    final order = arrangedGlanceIds(ids, state);
    final shown = [
      for (final glance in order)
        if (!state.hidden.contains(glance)) glance,
    ];
    final at = shown.indexOf(id);
    final to = at + by;
    if (at < 0 || to < 0 || to >= shown.length) return;
    final other = shown[to];
    final a = order.indexOf(id);
    final b = order.indexOf(other);
    order[a] = other;
    order[b] = id;
    _set(state.copyWith(order: order));
  }

  void _set(GlancePrefs next) {
    _touched = true;
    state = next;
    unawaited(_write());
  }

  /// The write in flight: the next waits for it, so quick changes never
  /// write the one file at once.
  Future<void> _writing = Future<void>.value();

  /// Settles once every change so far is on disk.
  Future<void> _write() =>
      _writing = _writing.then((_) => _writeNow(state.toJson()));

  Future<void> _writeNow(Map<String, Object?> json) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(json), flush: true);
    } on Object catch (e) {
      _log.warning('Keeping the glance layout failed: $e');
    }
  }

  /// Settles once every change so far is on disk; for a test.
  @visibleForTesting
  Future<void> get written => _writing;
}

final glancePrefsProvider =
    NotifierProvider<GlancePrefsController, GlancePrefs>(
      GlancePrefsController.new,
    );
