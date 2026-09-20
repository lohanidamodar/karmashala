import 'package:karmashala_core/logging.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// What the app can say about its own footprint in a build that has no VM
/// service.
///
/// The numbers are diagnostics, so what these pin is that the *line* is worth
/// reading: it arrives on an edge rather than on every tick, it carries the
/// slope rather than a bare number a reader would have to difference by hand,
/// and it names the collections that would let the growth be attributed.
void main() {
  late List<LogRecord> records;

  setUp(() {
    records = <LogRecord>[];
    AppLogger.initialize(level: Level.ALL, onRecord: records.add);
  });

  MemoryCensus census(
    int residentMib, {
    int panes = 0,
    int detached = 0,
    int unparsed = 0,
    int rows = 0,
    int chars = 0,
    int sessions = 0,
    int logLines = 0,
  }) => MemoryCensus(
    residentBytes: residentMib * 1024 * 1024,
    peakResidentBytes: residentMib * 1024 * 1024,
    panes: panes,
    detachedPanes: detached,
    unparsedPanes: unparsed,
    scrollbackRows: rows,
    heldScrollbackChars: chars,
    watchedSessions: sessions,
    logLinesHeld: logLines,
  );

  MemoryCensusLogger loggerOver(List<MemoryCensus> readings) {
    var next = 0;
    return MemoryCensusLogger(
      count: () => readings[next++],
      logger: AppLogger.named('memory'),
      stepBytes: 32 * 1024 * 1024,
    );
  }

  test(
    'the first reading is always printed, as the baseline to difference',
    () {
      loggerOver([census(300)]).sample();

      expect(records, hasLength(1));
      expect(records.single.message, contains('first reading'));
      expect(records.single.message, contains('resident 300 MiB'));
    },
  );

  test('a reading that has not moved a step says nothing', () {
    // 30 s apart at rest: a line per sample would be a ticker, and the log it
    // has to be readable in is the same one every other subsystem writes to.
    loggerOver([census(300), census(310), census(290)])
      ..sample()
      ..sample()
      ..sample();

    expect(records, hasLength(1));
  });

  test('growth past a step prints, with the slope and the samples it took', () {
    loggerOver([census(300), census(310), census(340)])
      ..sample()
      ..sample()
      ..sample();

    expect(records, hasLength(2));
    // The delta and the sample count, because a reader cannot difference
    // against a line a log rotation may already have dropped.
    expect(records.last.message, contains('+40 MiB'));
    expect(records.last.message, contains('over 2 samples'));
  });

  test('a release past a step prints too, and keeps its sign', () {
    loggerOver([census(900), census(800)])
      ..sample()
      ..sample();

    expect(records, hasLength(2));
    expect(records.last.message, contains('-100 MiB'));
  });

  test('every line carries the counters growth could be attributed to', () {
    loggerOver([
      census(
        512,
        panes: 6,
        detached: 2,
        unparsed: 3,
        rows: 41000,
        chars: 1200000,
        sessions: 16,
        logLines: 5000,
      ),
    ]).sample();

    final line = records.single.message;
    // Named rather than matched loosely: these are the words a bug report
    // will quote, and a counter that silently stops being printed is a
    // subsystem that silently stops being ruleable-out.
    expect(line, contains('6 panes (2 detached, 3 unparsed)'));
    expect(line, contains('41000 scrollback rows'));
    expect(line, contains('1200000 held chars'));
    expect(line, contains('16 sessions watched'));
    expect(line, contains('5000 log lines'));
  });

  test('a census that throws disarms itself instead of warning forever', () {
    final logger = MemoryCensusLogger(
      count: () => throw StateError('no counters'),
      logger: AppLogger.named('memory'),
    )..start();
    expect(logger.isSampling, isTrue);

    logger.sample();

    // One warning, and the timer gone: a census that cannot read its counters
    // must not turn into a line every interval for the rest of the run.
    expect(records.where((r) => r.level == Level.WARNING), hasLength(1));
    expect(logger.isSampling, isFalse);
    expect(logger.lastLogged, isNull);
  });

  test('a real process answers currentRss, which is what the census reads', () {
    // The whole design turns on this: a release build has no VM service, so if
    // `ProcessInfo` could not answer there would be nothing to log at all.
    final reading = readProcessResident();
    expect(reading.resident, greaterThan(0));
    expect(reading.peak, greaterThanOrEqualTo(reading.resident));
  });
}
