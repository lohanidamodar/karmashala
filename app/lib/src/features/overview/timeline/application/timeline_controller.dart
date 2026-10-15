import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../data/timeline_data.dart';
import '../domain/timeline_model.dart';

/// What the timeline shows: a stretch of time and which projects. A null
/// [projectIds] is every project.
@immutable
class TimelineQuery {
  const TimelineQuery({required this.from, required this.to, this.projectIds});

  final DateTime from;
  final DateTime to;
  final Set<String>? projectIds;

  bool admits(ActivityEntry entry) =>
      !entry.at.isBefore(from) &&
      entry.at.isBefore(to) &&
      (projectIds?.contains(entry.projectId) ?? true);

  @override
  bool operator ==(Object other) =>
      other is TimelineQuery &&
      other.from == from &&
      other.to == to &&
      setEquals(other.projectIds, projectIds);

  @override
  int get hashCode => Object.hash(
    from,
    to,
    projectIds == null ? null : Object.hashAllUnordered(projectIds!),
  );
}

/// The range shown: today by default, as local days.
@immutable
class TimelineRange {
  const TimelineRange({required this.from, required this.to});

  /// The local day holding [at].
  factory TimelineRange.dayOf(DateTime at) {
    final local = at.toLocal();
    final start = DateTime(local.year, local.month, local.day);
    return TimelineRange(
      from: start,
      to: DateTime(local.year, local.month, local.day + 1),
    );
  }

  final DateTime from;
  final DateTime to;

  bool get isOneDay => DateTime(from.year, from.month, from.day + 1) == to;

  /// The same length of days, [by] lengths later (or earlier).
  TimelineRange shifted(int by) {
    final length = isOneDay ? 1 : _daysBetween(from, to);
    return TimelineRange(
      from: DateTime(from.year, from.month, from.day + length * by),
      to: DateTime(to.year, to.month, to.day + length * by),
    );
  }

  static int _daysBetween(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  @override
  bool operator ==(Object other) =>
      other is TimelineRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Which range the timeline shows.
class TimelineRangeController extends Notifier<TimelineRange> {
  TimelineRangeController([DateTime Function()? clock])
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  @override
  TimelineRange build() => TimelineRange.dayOf(_clock());

  void previous() => state = state.shifted(-1);
  void next() => state = state.shifted(1);
  void today() => state = TimelineRange.dayOf(_clock());

  /// The local days [first] through [last], both included.
  void days(DateTime first, DateTime last) => state = TimelineRange(
    from: DateTime(first.year, first.month, first.day),
    to: DateTime(last.year, last.month, last.day + 1),
  );

  DateTime get _lastDay =>
      DateTime(state.to.year, state.to.month, state.to.day - 1);

  /// The range's last day on its own.
  void day() => days(_lastDay, _lastDay);

  /// The seven days ending on the range's last day.
  void week() {
    final last = _lastDay;
    days(DateTime(last.year, last.month, last.day - 6), last);
  }
}

/// What the Timeline narrows to on this device: machines (null for all),
/// words in a title, and whether only waits on the owner stand out.
@immutable
class TimelineViewFilter {
  const TimelineViewFilter({
    this.machines,
    this.query = '',
    this.waitsOnly = false,
  });

  final Set<String>? machines;
  final String query;
  final bool waitsOnly;

  bool admits(TimelineSession session) {
    final words = query.trim().toLowerCase();
    return (machines == null || machines!.contains(session.machine ?? '')) &&
        (words.isEmpty || session.title.toLowerCase().contains(words));
  }

  TimelineViewFilter copyWith({
    Set<String>? Function()? machines,
    String? query,
    bool? waitsOnly,
  }) => TimelineViewFilter(
    machines: machines == null ? this.machines : machines(),
    query: query ?? this.query,
    waitsOnly: waitsOnly ?? this.waitsOnly,
  );
}

class TimelineViewFilterController extends Notifier<TimelineViewFilter> {
  @override
  TimelineViewFilter build() => const TimelineViewFilter();

  void search(String query) => state = state.copyWith(query: query);
  void waitsOnly(bool on) => state = state.copyWith(waitsOnly: on);
  void allMachines() => state = state.copyWith(machines: () => null);

  /// Shows or hides [machine], out of [all] when every one was shown.
  void toggleMachine(String machine, Iterable<String> all) {
    final every = all.toSet();
    final shown = {...(state.machines ?? every)};
    if (!shown.remove(machine)) shown.add(machine);
    state = state.copyWith(
      machines: () => shown.length == every.length ? null : shown,
    );
  }
}

final timelineViewFilterProvider =
    NotifierProvider<TimelineViewFilterController, TimelineViewFilter>(
      TimelineViewFilterController.new,
    );

final timelineRangeProvider =
    NotifierProvider<TimelineRangeController, TimelineRange>(
      TimelineRangeController.new,
    );

/// Which projects are rows; null for every project. Kept for this window.
class TimelineProjectFilter extends Notifier<Set<String>?> {
  @override
  Set<String>? build() => null;

  void showAll() => state = null;

  /// Shows or hides [projectId], out of [all] when every one was shown.
  void toggle(String projectId, Iterable<String> all) {
    final shown = {...(state ?? all.toSet())};
    if (!shown.remove(projectId)) shown.add(projectId);
    state = shown.length == all.toSet().length ? null : shown;
  }
}

final timelineProjectFilterProvider =
    NotifierProvider<TimelineProjectFilter, Set<String>?>(
      TimelineProjectFilter.new,
    );

/// The log's entries for a query, read once and kept current as the server
/// appends.
final timelineEntriesProvider = StreamProvider.autoDispose
    .family<List<ActivityEntry>, TimelineQuery>((ref, query) {
      final data = ref.watch(timelineDataProvider);
      final out = StreamController<List<ActivityEntry>>();
      final byId = <int, ActivityEntry>{};
      final early = <ActivityEntry>[];
      var loaded = false;

      List<ActivityEntry> sorted() => byId.values.toList()
        ..sort((a, b) {
          final at = a.at.compareTo(b.at);
          return at != 0 ? at : a.id.compareTo(b.id);
        });

      final appended = data.appended.listen((entries) {
        final fits = entries.where(query.admits);
        if (fits.isEmpty) return;
        if (!loaded) {
          early.addAll(fits);
          return;
        }
        for (final entry in fits) {
          byId[entry.id] = entry;
        }
        if (!out.isClosed) out.add(sorted());
      });
      data
          .range(
            from: query.from.toUtc(),
            to: query.to.toUtc(),
            projectIds: query.projectIds?.toList(),
          )
          .then(
            (entries) {
              for (final entry in [...entries, ...early]) {
                byId[entry.id] = entry;
              }
              loaded = true;
              if (!out.isClosed) out.add(sorted());
            },
            onError: (Object error, StackTrace stack) {
              if (!out.isClosed) out.addError(error, stack);
            },
          );
      ref.onDispose(() {
        appended.cancel();
        out.close();
      });
      return out.stream;
    });
