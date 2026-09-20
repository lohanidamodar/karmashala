import 'dart:async';
import 'dart:io';

import 'app_logger.dart';

/// How often the process is sampled. The growth this was written for ran at
/// ~17.5 MB/min, so 30 s is six readings in the three minutes somebody takes to
/// notice a slowdown — and a reading is one `currentRss` plus a walk of maps
/// that are already in memory.
const Duration kMemoryCensusInterval = Duration(seconds: 30);

/// How far resident size must move from the last line **printed** before
/// another is. A GC sawtooth of a few tens of MiB stays silent; growth at the
/// reported rate prints roughly every two minutes.
const int kMemoryCensusStepBytes = 32 * 1024 * 1024;

/// What the process is holding, as far as it can see itself.
///
/// **`residentBytes` cannot be attributed.** It is the whole process — Dart
/// heap, Flutter's rasterizer, and every native allocation this app never
/// touches: libmpv, ConPTY's console buffers, sqlite's page cache, the Windows
/// loader. A resident size that climbs while every counter below stays flat
/// therefore proves only that the growth is *not* in these collections. It does
/// not say the Dart heap is innocent, and nothing here can: a release build has
/// no VM service to ask.
///
/// The counters are the ones that can be read in O(panes + 1). They are here to
/// let a reader rule a subsystem in or out, not to add up to [residentBytes].
/// Nothing counts parsed transcripts, because nothing retains them: every
/// consumer is an `autoDispose` provider holding one list at a time.
class MemoryCensus {
  const MemoryCensus({
    required this.residentBytes,
    required this.peakResidentBytes,
    required this.panes,
    required this.detachedPanes,
    required this.unparsedPanes,
    required this.scrollbackRows,
    required this.heldScrollbackChars,
    required this.watchedSessions,
    required this.logLinesHeld,
  });

  /// `ProcessInfo.currentRss`. Available in a release build, unlike the VM
  /// service — measured, not assumed; see `docs/SETTLED.md`.
  final int residentBytes;

  /// `ProcessInfo.maxRss`: the high-water mark, which never falls. A resident
  /// size well under it is memory that was released, not memory never taken.
  final int peakResidentBytes;

  /// Pane instances the terminal controller holds, live or restored.
  final int panes;

  /// Sessions still running with no tab showing them — kept, not closed.
  final int detachedPanes;

  /// Panes of [panes] whose buffer has never been built, so they hold text
  /// rather than rows and are absent from [scrollbackRows].
  final int unparsedPanes;

  /// Rows across every parsed pane buffer, scrollback included. The pane cost
  /// that grows with *use* rather than with pane count.
  final int scrollbackRows;

  /// Scrollback held as text rather than as rows: the autosave's last encoding
  /// per pane, plus what a parked pane holds in place of a buffer. UTF-16, so
  /// bytes are roughly twice this.
  final int heldScrollbackChars;

  /// Sessions the status registry holds a status for.
  final int watchedSessions;

  /// Records in the diagnostics ring. Bounded by construction, so a number at
  /// the bound is the bound working, not a leak.
  final int logLinesHeld;

  static String _mib(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';

  /// A delta, with its sign kept: `-40 MiB` is a release and reads differently
  /// from `+40 MiB`.
  static String signedMib(int bytes) =>
      '${bytes < 0 ? '-' : '+'}${_mib(bytes.abs())}';

  /// The one-line form the log uses, so a bug report carries the same words a
  /// test asserts.
  @override
  String toString() =>
      'resident ${_mib(residentBytes)} · peak ${_mib(peakResidentBytes)} · '
      '$panes panes ($detachedPanes detached, $unparsedPanes unparsed) · '
      '$scrollbackRows scrollback rows · $heldScrollbackChars held chars · '
      '$watchedSessions sessions watched · $logLinesHeld log lines';
}

/// Samples [count] on a timer and logs it on an edge.
///
/// It logs the first reading and then only when resident size has moved
/// [stepBytes] from the last line printed — the same rule
/// `SessionStatusRegistry` uses, because a line every tick is a ticker nobody
/// reads rather than a diagnostic.
class MemoryCensusLogger {
  MemoryCensusLogger({
    required this.count,
    AppLogger? logger,
    this.interval = kMemoryCensusInterval,
    this.stepBytes = kMemoryCensusStepBytes,
  }) : _log = logger ?? AppLogger.named('memory');

  /// Takes one reading. The caller owns which collections it can reach.
  final MemoryCensus Function() count;
  final AppLogger _log;
  final Duration interval;
  final int stepBytes;

  Timer? _timer;
  MemoryCensus? _lastLogged;
  int _samplesSinceLine = 0;

  /// The last reading printed, or null before the first sample.
  MemoryCensus? get lastLogged => _lastLogged;

  /// Whether the timer is still armed. False after a census that threw.
  bool get isSampling => _timer != null;

  /// Begins sampling. The first reading is taken after [interval], not now:
  /// resident size during bootstrap is a number about bootstrap.
  void start() {
    _timer ??= Timer.periodic(interval, (_) => sample());
  }

  /// Takes one reading and logs it if it has moved. Public so a test drives the
  /// rule without a real clock; the timer calls nothing else.
  void sample() {
    final MemoryCensus census;
    try {
      census = count();
    } catch (error, stack) {
      // A census that throws must not take down what it is measuring, and must
      // not go on throwing every interval either.
      _log.warning(
        'The memory census could not read its counters.',
        error,
        stack,
      );
      dispose();
      return;
    }
    final previous = _lastLogged;
    _samplesSinceLine++;
    if (previous != null &&
        (census.residentBytes - previous.residentBytes).abs() < stepBytes) {
      return;
    }
    // The slope, in the units the reader has: how far it moved and over how
    // many samples of a known [interval]. A bare number cannot be differenced
    // against a line that may have been dropped from a rotated log.
    final moved = previous == null
        ? 'first reading'
        : '${MemoryCensus.signedMib(census.residentBytes - previous.residentBytes)} '
              'over $_samplesSinceLine samples';
    _lastLogged = census;
    _samplesSinceLine = 0;
    _log.info('$moved — $census');
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// [MemoryCensus.residentBytes] and [MemoryCensus.peakResidentBytes] from the
/// running process. Separated so a test can build a census without one.
({int resident, int peak}) readProcessResident() =>
    (resident: ProcessInfo.currentRss, peak: ProcessInfo.maxRss);
