import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/benchmark/agent_process_cost_bench.dart';

/// The parsers and the refusal behind `tool/benchmark/agent_process_cost_bench`.
///
/// The harness itself is run by hand against real agent CLIs; what is asserted
/// here is everything that can be asserted **without** another process: that
/// `Get-Process` and `/proc` output is read correctly, that a field the OS
/// withheld stays unknown rather than becoming a zero, and — the one that
/// matters most — that nothing is ever sampled on the strength of its name.
/// The owner's own `claude` and `codex` sessions are running on the same
/// machine as this suite.
void main() {
  group('CSV, as PowerShell writes it', () {
    test('quotes protect commas and are doubled to escape themselves', () {
      expect(
        splitCsvLine('"1234","dart","claude.exe --model ""opus"", -p"'),
        ['1234', 'dart', 'claude.exe --model "opus", -p'],
      );
    });

    test('an empty cell is empty, not absent', () {
      expect(splitCsvLine('"1","","3"'), ['1', '', '3']);
    });
  });

  group('parseGetProcessCsv', () {
    test('reads the four columns the sampler asks for', () {
      final readings = parseGetProcessCsv('''
"Id","ProcessName","CPU","WorkingSet64"
"4242","dart","12.34375","134217728"
"77","claude","0.796875","52428800"
''');
      expect(readings, hasLength(2));
      expect(readings.first.pid, 4242);
      expect(readings.first.name, 'dart');
      expect(readings.first.cpuSeconds, 12.34375);
      expect(readings.first.rssBytes, 134217728);
      expect(readings.last.pid, 77);
    });

    test('a CPU the OS would not give us stays unknown, never zero', () {
      // PowerShell leaves the cell empty for a process whose times this user
      // may not read. A zero there would report a busy agent as idle, which is
      // the confident false statement §19 exists to delete.
      final readings = parseGetProcessCsv('''
"Id","ProcessName","CPU","WorkingSet64"
"9","secret","","1048576"
''');
      expect(readings.single.cpuSeconds, isNull);
      expect(readings.single.rssBytes, 1048576);
    });

    test('a row with no readable pid is dropped rather than guessed', () {
      final readings = parseGetProcessCsv('''
"Id","ProcessName","CPU","WorkingSet64"
"","ghost","1.0","1"
"5","real","1.0","1"
''');
      expect(readings.map((r) => r.pid), [5]);
    });

    test('a header with no rows is no readings, not an error', () {
      expect(parseGetProcessCsv('"Id","ProcessName","CPU","WorkingSet64"\n'), isEmpty);
      expect(parseGetProcessCsv(''), isEmpty);
    });
  });

  group('parseWin32ProcessCsv', () {
    test('a command line survives its own commas and quotes', () {
      final identities = parseWin32ProcessCsv('''
"ProcessId","ParentProcessId","CommandLine"
"4242","1000","""C:\\bin\\claude.exe"" --model opus, -p ""go"""
''');
      expect(identities.single.pid, 4242);
      expect(identities.single.parentPid, 1000);
      expect(
        identities.single.commandLine,
        r'"C:\bin\claude.exe" --model opus, -p "go"',
      );
    });

    test('a command line we could not read is null, and stays null', () {
      final identities = parseWin32ProcessCsv('''
"ProcessId","ParentProcessId","CommandLine"
"4","0",""
''');
      expect(identities.single.commandLine, isNull);
    });
  });

  group('parseProcStat', () {
    // A real line, with the two hazards that break every naive parser: the
    // executable name holds a space and a closing parenthesis.
    const line =
        '4242 (dart (deleted)) S 1000 4242 4242 0 -1 4194304 9000 0 0 0 '
        '1200 300 0 0 20 0 12 0 99 2147483648 32768 18446744073709551615 '
        '1 1 0 0 0 0 0 0 0 0 0 0 17 4 0 0 0 0 0';

    test('the name is taken at the last parenthesis, not at a field count', () {
      expect(splitProcStat(line)!.comm, 'dart (deleted)');
      expect(splitProcStat(line)!.after.first, 'S');
    });

    test('CPU is utime + stime in clock ticks, and rss is in pages', () {
      final reading = parseProcStat(
        line,
        pid: 4242,
        clockTicks: 100,
        pageSize: 4096,
      )!;
      expect(reading.cpuSeconds, (1200 + 300) / 100);
      expect(reading.rssBytes, 32768 * 4096);
      expect(reading.name, 'dart (deleted)');
    });

    test('a line too short to hold the fields is not a reading', () {
      expect(
        parseProcStat('1 (x) S 0', pid: 1, clockTicks: 100, pageSize: 4096),
        isNull,
      );
      expect(
        parseProcStat('', pid: 1, clockTicks: 100, pageSize: 4096),
        isNull,
      );
    });
  });

  group('fillMissing', () {
    test('a pid that did not answer is a row of unknowns, never a dropped row', () {
      // `Get-Process -Id` prints only the processes that still exist and exits
      // 1 for the rest. Dropping those rows would make each sample shorter and
      // therefore make the machine look cheaper than it was.
      final rows = fillMissing(const [1, 2, 3], const [
        ProcessReading(pid: 2, name: 'dart', cpuSeconds: 1, rssBytes: 4096),
      ]);
      expect(rows.map((r) => r.pid), [1, 2, 3]);
      expect(rows.first.cpuSeconds, isNull);
      expect(rows.first.rssBytes, isNull);
      expect(rows.first.name, isNull);
      expect(rows[1].name, 'dart');
    });
  });

  group('descendantsOf', () {
    test('the whole tree below the root, and nothing beside it', () {
      final tree = descendantsOf(10, const [
        ProcessIdentity(pid: 10, parentPid: 1, commandLine: 'app'),
        ProcessIdentity(pid: 11, parentPid: 10, commandLine: 'claude'),
        ProcessIdentity(pid: 12, parentPid: 11, commandLine: 'node'),
        // The owner's own session: same name, not our child.
        ProcessIdentity(pid: 99, parentPid: 1, commandLine: 'claude'),
      ]);
      expect(tree, {10, 11, 12});
    });

    test('a parentage cycle from pid reuse terminates', () {
      final tree = descendantsOf(1, const [
        ProcessIdentity(pid: 1, parentPid: 2, commandLine: 'a'),
        ProcessIdentity(pid: 2, parentPid: 1, commandLine: 'b'),
      ]);
      expect(tree, {1, 2});
    });
  });

  group('what may be measured', () {
    const ours = [
      ProcessIdentity(pid: 10, parentPid: 1, commandLine: 'flutter test'),
      ProcessIdentity(pid: 11, parentPid: 10, commandLine: 'claude -p go'),
      ProcessIdentity(pid: 99, parentPid: 1, commandLine: 'claude'),
    ];

    test("a stranger's session is never in the plan, whatever it is called", () {
      final plan = planFor(10, ours);
      expect(plan.refusal, isNull);
      expect(plan.pids, [10, 11]);
      expect(plan.names[11], 'claude -p go');
      expect(plan.pids, isNot(contains(99)));
    });

    test('no table, no run', () {
      final plan = planFor(10, const []);
      expect(plan.pids, isEmpty);
      expect(plan.refusal, contains('nothing here can be shown to be'));
      expect(plan.refusal, contains('process name'));
    });

    test('a table that does not contain us is not describing this machine', () {
      final plan = planFor(777, ours);
      expect(plan.refusal, contains('777'));
    });

    test('a child we cannot describe stops the run rather than being dropped', () {
      // Dropping it quietly would make the sample smaller and therefore make
      // the machine look cheaper, which is the direction that lies.
      final plan = planFor(10, const [
        ProcessIdentity(pid: 10, parentPid: 1, commandLine: 'flutter test'),
        ProcessIdentity(pid: 11, parentPid: 10, commandLine: null),
      ]);
      expect(plan.pids, isEmpty);
      expect(plan.refusal, contains('11'));
      expect(plan.refusal, contains('will not measure'));
    });
  });

  group('the table', () {
    test('a first sample has no percentage, and a withheld field says so', () async {
      final probe = _ScriptedProbe([
        const [
          ProcessReading(pid: 10, name: 'dart', cpuSeconds: 1, rssBytes: 1048576),
          ProcessReading(pid: 11, name: 'claude', rssBytes: 2097152),
        ],
        const [
          ProcessReading(pid: 10, name: 'dart', cpuSeconds: 2, rssBytes: 2097152),
          ProcessReading(pid: 11, name: 'claude', rssBytes: 2097152),
        ],
      ]);
      final samples = await sample(
        probe,
        pids: const [10, 11],
        samples: 2,
        interval: const Duration(seconds: 1),
        // Counted, not waited on: the gate must never spend a second to watch
        // a clock. The harness's own run is the thing allowed to time.
        wait: (_) async {},
      );
      final table = renderTable(samples, own: 10, named: const {
        10: 'flutter test',
        11: 'claude -p go',
      });
      expect(table, contains('the app itself'));
      // The first row of each process: nothing to difference against.
      expect(table, contains('—'));
      // Every reading of pid 11 lacked a CPU number.
      expect(table, contains('?'));
      expect(table, contains('1.0M'));
    });

    test('nothing sampled says so rather than printing an empty grid', () {
      expect(renderTable(const [], own: 1), contains('nothing was sampled'));
    });
  });

  group('the dry run — this process tree, with no agents in it', () {
    test('it either measures what it proved is ours, or refuses in words', () async {
      final probe = await SystemProcessProbe.forHost();
      if (probe == null) {
        // macOS: `Get-Process` and `/proc` are both absent, and this harness
        // says so rather than inventing a third reader it has never run.
        expect(Platform.isWindows || Platform.isLinux, isFalse);
        return;
      }
      final plan = await planSampling(probe, rootPid: pid);
      if (plan.refusal != null) {
        // A legitimate outcome on a real machine: Windows recycles pids, so a
        // stale row can name this process as its parent and bring in something
        // whose command line this user may not read. Refusing is the correct
        // direction, and the refusal has to say why.
        expect(plan.refusal, isNotEmpty);
        return;
      }
      expect(plan.pids, contains(pid));
      expect(plan.names[pid], isNotNull);
      final samples = await sample(
        probe,
        pids: plan.pids,
        samples: 2,
        interval: const Duration(milliseconds: 1),
        wait: (_) async {},
      );
      // Every requested pid gets a row, this process among them. Its own
      // numbers are the ones that must be real: it is the process we are
      // certainly allowed to read.
      expect(
        samples.last.readings.map((r) => r.pid),
        plan.pids,
        reason: 'every pid asked for must have a row',
      );
      final own = samples.last.readings.singleWhere((r) => r.pid == pid);
      expect(own.rssBytes, isNotNull);
      expect(own.cpuSeconds, isNotNull);
      expect(
        renderTable(samples, own: pid, named: plan.names),
        contains('<- the app itself'),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

/// A probe that answers from a script, so the table can be asserted without a
/// second process.
class _ScriptedProbe implements SystemProcessProbe {
  _ScriptedProbe(this._readings);

  final List<List<ProcessReading>> _readings;
  int _next = 0;

  @override
  Future<List<ProcessIdentity>> identities() async => const [];

  @override
  Future<List<ProcessReading>> read(List<int> pids) async =>
      _readings[_next++ % _readings.length];
}
