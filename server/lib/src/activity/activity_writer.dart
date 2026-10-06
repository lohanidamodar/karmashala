import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'activity_log.dart';

/// Writes the activity log off the caller's turn: drafts are queued and
/// written in one transaction a moment later, and a write that fails is
/// logged and dropped, never thrown at whoever saw the edge. Every write —
/// its own, and the rows the store's triggers wrote — is pushed to clients
/// by reading the log after the last id told.
class ActivityWriter {
  ActivityWriter({
    required List<ActivityEntry> Function(List<ActivityDraft> drafts) append,
    required List<ActivityEntry> Function(int afterId) tail,
    required int lastId,
    required void Function(List<ActivityEntry> entries) announce,
    void Function(String message)? log,
    this.delay = const Duration(milliseconds: 250),
  }) : _append = append,
       _tail = tail,
       _told = lastId,
       _announce = announce,
       _log = log;

  final List<ActivityEntry> Function(List<ActivityDraft> drafts) _append;
  final List<ActivityEntry> Function(int afterId) _tail;
  final void Function(List<ActivityEntry> entries) _announce;
  final void Function(String message)? _log;
  final Duration delay;

  final List<ActivityDraft> _queue = [];
  Timer? _timer;
  Completer<void>? _pending;
  int _told;
  var _closed = false;

  /// Queues [draft]; returns at once.
  void record(ActivityDraft draft) {
    if (_closed) return;
    _queue.add(draft);
    _schedule();
  }

  /// Something may have written the log directly (a trigger): tell it soon.
  void nudge() {
    if (_closed) return;
    _schedule();
  }

  /// Completes once what is queued now has been written and told.
  Future<void> get flushed => _pending?.future ?? Future<void>.value();

  void _schedule() {
    _pending ??= Completer<void>();
    _timer ??= Timer(delay, _flush);
  }

  void _flush() {
    _timer = null;
    final pending = _pending;
    _pending = null;
    final drafts = List.of(_queue);
    _queue.clear();
    if (drafts.isNotEmpty) {
      try {
        _append(drafts);
      } on Object catch (error) {
        _log?.call('${drafts.length} activity entries not written ($error)');
      }
    }
    try {
      final appended = _tail(_told);
      if (appended.isNotEmpty) {
        _told = appended.last.id;
        _announce(appended);
      }
    } on Object catch (error) {
      _log?.call('activity entries not told ($error)');
    }
    pending?.complete();
  }

  /// Writes what is queued, then stops taking more.
  Future<void> close() async {
    if (_timer != null) {
      _timer!.cancel();
      _flush();
    }
    _closed = true;
  }
}
