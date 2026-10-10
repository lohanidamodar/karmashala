import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show CapacitySnapshot;
import 'package:path/path.dart' as p;

import '../../explorer/application/agent_states.dart';
import 'overview_board.dart';
import 'overview_prefs.dart';

/// The parts of the Today strip, each a filter on the Board.
enum OverviewTodayPart {
  needsYou,
  finished,
  stuck,
  running;

  /// The columns and states this part narrows the Board to.
  ({Set<BoardColumn> columns, Set<AgentState>? states}) get filter =>
      switch (this) {
        needsYou => (
          columns: {BoardColumn.needsYou},
          states: {AgentState.needsYou},
        ),
        finished => (
          columns: {BoardColumn.ready, BoardColumn.done},
          states: null,
        ),
        stuck => (
          columns: {BoardColumn.needsYou, BoardColumn.working},
          states: {AgentState.failed, AgentState.quiet},
        ),
        running => (columns: {BoardColumn.working}, states: null),
      };

  /// Whether [filter] is this part's own.
  bool selectedIn(OverviewFilter filter) {
    final own = this.filter;
    final columns = filter.columns;
    final states = filter.states;
    bool same<T>(Set<T>? a, Set<T>? b) => a == null
        ? b == null
        : b != null && a.length == b.length && a.containsAll(b);
    return columns != null &&
        same(own.columns, columns) &&
        same(own.states, states);
  }
}

/// **Today, in one line**: what waits on you, what finished since you last
/// looked, what is stuck and what runs.
@immutable
class OverviewToday {
  const OverviewToday({
    this.needsYou = 0,
    this.oldestWait,
    this.firstWaitingId,
    this.finished = const [],
    this.failed = 0,
    this.quiet = 0,
    this.slotWaiting = 0,
    this.running = 0,
    this.limit,
    this.gatesWaiting = 0,
    this.pipelinesFailed = 0,
  });

  /// Sessions waiting on you, and pipeline gates waiting for approval.
  final int needsYou;

  /// Of [needsYou], the pipeline runs waiting at a gate.
  final int gatesWaiting;

  /// Pipeline runs the dashboard shows that failed: stuck until retried or
  /// skipped on.
  final int pipelinesFailed;
  final Duration? oldestWait;

  /// The session whose question has waited longest.
  final String? firstWaitingId;

  /// Sessions done with their turn, or ended, since the last look.
  final List<String> finished;

  final int failed;
  final int quiet;

  /// Launches waiting for a concurrency slot.
  final int slotWaiting;

  final int running;

  /// The global concurrency limit; null when none is set.
  final int? limit;

  int get stuck => failed + quiet + slotWaiting + pipelinesFailed;

  int countOf(OverviewTodayPart part) => switch (part) {
    OverviewTodayPart.needsYou => needsYou,
    OverviewTodayPart.finished => finished.length,
    OverviewTodayPart.stuck => stuck,
    OverviewTodayPart.running => running,
  };

  /// "3/4 running · 1 waiting" with a limit set, else "3 running".
  String get runningLabel => [
    limit == null ? '$running running' : '$running/$limit running',
    if (slotWaiting > 0) '$slotWaiting waiting',
  ].join(' · ');

  /// "1 quiet · 1 failed · 1 waiting for a slot".
  String get stuckDetail => [
    if (quiet > 0) '$quiet quiet',
    if (failed > 0) '$failed failed',
    if (slotWaiting > 0) '$slotWaiting waiting for a slot',
    if (pipelinesFailed > 0)
      pipelinesFailed == 1
          ? '1 pipeline failed'
          : '$pipelinesFailed pipelines failed',
  ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is OverviewToday &&
      other.needsYou == needsYou &&
      other.oldestWait == oldestWait &&
      other.firstWaitingId == firstWaitingId &&
      other.finished.length == finished.length &&
      other.finished.every(finished.contains) &&
      other.failed == failed &&
      other.quiet == quiet &&
      other.slotWaiting == slotWaiting &&
      other.running == running &&
      other.limit == limit &&
      other.gatesWaiting == gatesWaiting &&
      other.pipelinesFailed == pipelinesFailed;

  @override
  int get hashCode => Object.hash(
    needsYou,
    oldestWait,
    firstWaitingId,
    Object.hashAllUnordered(finished),
    failed,
    quiet,
    slotWaiting,
    running,
    limit,
    gatesWaiting,
    pipelinesFailed,
  );
}

/// Today over every session [board] holds. [lookedAt] is the last look at
/// the dashboard; never looked, the day so far counts. [firstWaitingId] is
/// the head of the Board's queue, which orders what waits.
OverviewToday overviewTodayOf(
  OverviewBoard board, {
  required OverviewStrip strip,
  required CapacitySnapshot capacity,
  required DateTime? lookedAt,
  required DateTime startOfToday,
  String? firstWaitingId,
  int gatesWaiting = 0,
  int pipelinesFailed = 0,
}) {
  final since = lookedAt ?? startOfToday;
  final finished = [
    for (final MapEntry(key: id, value: state) in board.states.entries)
      if ((state == AgentState.ready || state == AgentState.ended) &&
          (board.activeAt[id]?.isAfter(since) ?? false))
        id,
  ];
  final limit = capacity.limits.global;
  return OverviewToday(
    needsYou: strip.needsYou + gatesWaiting,
    oldestWait: strip.oldestWait,
    firstWaitingId: strip.needsYou == 0 ? null : firstWaitingId,
    gatesWaiting: gatesWaiting,
    pipelinesFailed: pipelinesFailed,
    finished: finished,
    failed: strip.failed,
    quiet: strip.quiet,
    slotWaiting: capacity.waiters.length,
    running: limit == null ? strip.working : capacity.running,
    limit: limit,
  );
}

/// **When the dashboard was last looked at**, on this device: when it was
/// left, or "Seen" was pressed. Null until either has happened once.
class OverviewLookedAtController extends Notifier<DateTime?> {
  static final _log = AppLogger.named('overview.looked');
  var _touched = false;

  @override
  DateTime? build() {
    unawaited(_load());
    return null;
  }

  Future<File> _file() async => File(
    p.join(
      (await ref.read(overviewPrefsDirectoryProvider)()).path,
      'overview_looked.json',
    ),
  );

  Future<void> _load() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      final at = json is Map ? DateTime.tryParse('${json['at']}') : null;
      if (ref.mounted && !_touched && at != null) state = at.toUtc();
    } on Object {
      // Never looked, or unreadable: the day so far counts.
    }
  }

  /// The dashboard was looked at, at [at].
  void markLooked(DateTime at) {
    if (!ref.mounted) return;
    _touched = true;
    state = at.toUtc();
    unawaited(_write(at.toUtc()));
  }

  Future<void> _write(DateTime at) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'at': at.toIso8601String()}),
        flush: true,
      );
    } on Object catch (e) {
      _log.warning('Keeping when the dashboard was looked at failed: $e');
    }
  }
}

final overviewLookedAtProvider =
    NotifierProvider<OverviewLookedAtController, DateTime?>(
      OverviewLookedAtController.new,
    );
