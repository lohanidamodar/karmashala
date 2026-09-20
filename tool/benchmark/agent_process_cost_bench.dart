import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Benchmark — NOT part of `flutter test`'s default run. It lives under `tool/`
/// so discovery never picks it up. Run it by hand:
///
///   cmd.exe /c "cd /d C:\path\to\repo && \
///     C:\Users\<you>\flutter\bin\cache\dart-sdk\bin\dart.exe --disable-dart-dev \
///     --packages=C:\Users\<you>\flutter\packages\flutter_tools\.dart_tool\package_config.json \
///     C:\Users\<you>\flutter\bin\cache\flutter_tools.snapshot \
///     test tool/benchmark/agent_process_cost_bench.dart"
///
/// Or, more simply, from a Windows shell:
///
///   flutter test tool/benchmark/agent_process_cost_bench.dart
///
/// Three environment variables, all optional:
///
///   KARMASHALA_BENCH_ROOT_PID     the process whose tree to measure
///                                 (default: this one)
///   KARMASHALA_BENCH_SAMPLES      how many samples to take (default 10)
///   KARMASHALA_BENCH_INTERVAL_MS  milliseconds between them (default 1000)
///
/// ## How to get agents into the tree
///
/// The harness measures **the tree it is rooted at**, and with no root given
/// that is the harness itself — which, with no agents under it, is the dry run
/// the unit tests pin. To measure real agent CLIs, start Karmashala, open the
/// N sessions being measured, and give this its pid:
///
///   `KARMASHALA_BENCH_ROOT_PID=<karmashala pid> flutter test tool/benchmark/…`
///
/// **Start one for the measurement; do not point it at the owner's live
/// sessions.** Nothing here signals or writes to a process — it reads
/// `Get-Process` and `/proc` and nothing else — so the cost of getting that
/// wrong is a table about the wrong work, not a lost session. It is still the
/// wrong table.
///
/// ## The question, and why it is not a unit gate
///
/// *What do N agents cost this machine?* `test/features/scale/` holds the other
/// three benchmark gates — quiet soak, degraded disk, churn/leak — and this one
/// was **refused** as a fourth, not deferred: `flutter test` cannot see another
/// process's CPU or resident set at all, and `ProcessInfo.currentRss` measures
/// the *tester's* own Dart heap under a GC no test controls. A number that
/// looks like an answer and means nothing is worse than no number.
///
/// So it is a harness, run by hand, against **real** agent CLIs running as
/// separate OS processes. It samples over a stated interval and prints a table:
/// one row per process per sample, and the app's own process among them,
/// because the interesting number is always a ratio.
///
/// ## It will not sample a process it cannot prove is ours
///
/// The owner's own `claude`, `codex` and `agy` sessions are running on the same
/// machine as this, and their names are the same names. **Nothing here matches
/// on a process name**, ever: the candidate set is the transitive set of
/// *children* of a root pid, computed from a parentage table this reads for
/// itself, and a pid that is not in that table — or whose command line could
/// not be read — is refused rather than guessed at. If the table itself cannot
/// be read, the whole run refuses: an empty parentage table proves nothing is
/// ours rather than proving everything is.
///
/// That is the same discipline as never killing a `dart.exe` you did not
/// prove you started.
///
/// ## Where the numbers come from
///
/// | | CPU | resident set | parentage + command line |
/// | --- | --- | --- | --- |
/// | Windows | `Get-Process` `CPU` | `Get-Process` `WorkingSet64` | `Get-CimInstance Win32_Process` |
/// | Linux | `/proc/<pid>/stat` utime+stime | `/proc/<pid>/stat` rss × page size | `/proc/<pid>/stat` ppid, `/proc/<pid>/cmdline` |
///
/// `Get-Process`'s `CPU` and `/proc`'s utime+stime are both **cumulative** —
/// processor seconds since the process started — so a percentage is the
/// difference between two samples over the wall clock between them, and the
/// first sample of every process has no percentage at all. That is reported as
/// a dash and never as a zero (§19): a reading with nothing before it is not a
/// reading of no work.
///
/// A field the OS would not give us — `CPU` is empty for a process this user
/// may not open — stays null the whole way through and prints as `?`.
///
/// ## Two things a first reader will notice in the output
///
/// **The interval is a floor, not a period.** On Windows each sample costs a
/// PowerShell spawn, measured at roughly 700 ms on the owner's machine, so a
/// requested 700 ms lands about 1.4 s apart. Nothing is corrected for: every
/// percentage is computed over the wall clock actually elapsed between the two
/// readings, and the `elapsed` column is the real one.
///
/// **`?` rows are the harness's own helpers.** The parentage table is read by
/// spawning PowerShell, and that PowerShell is genuinely a child of this
/// process at the moment the table names it — and gone by the time the first
/// sample asks about it. It shows as a row of `?` rather than disappearing,
/// which is the same rule that keeps an agent that died mid-run visible.
void main() {
  test('agent process cost, sampled', () async {
    final probe = await SystemProcessProbe.forHost();
    if (probe == null) {
      // ignore: avoid_print
      print(
        'No process probe for ${Platform.operatingSystem}: this harness knows '
        'Windows and Linux. Nothing was sampled.',
      );
      return;
    }
    final root = _intFromEnv('KARMASHALA_BENCH_ROOT_PID', pid);
    final plan = await planSampling(probe, rootPid: root);
    if (plan.refusal != null) {
      // ignore: avoid_print
      print('REFUSED: ${plan.refusal}');
      return;
    }
    final table = await sample(
      probe,
      pids: plan.pids,
      samples: _intFromEnv('KARMASHALA_BENCH_SAMPLES', 10),
      interval: Duration(
        milliseconds: _intFromEnv('KARMASHALA_BENCH_INTERVAL_MS', 1000),
      ),
    );
    // ignore: avoid_print
    print(renderTable(table, own: root, named: plan.names));
  }, timeout: const Timeout(Duration(minutes: 5)));
}

int _intFromEnv(String name, int fallback) {
  final raw = Platform.environment[name];
  final value = raw == null ? null : int.tryParse(raw.trim());
  return value == null || value <= 0 ? fallback : value;
}

/// One process's CPU and resident set at one moment.
///
/// Every field but [pid] is nullable, and each null means *the OS did not tell
/// us*. None of them is ever defaulted to zero.
class ProcessReading {
  const ProcessReading({
    required this.pid,
    this.name,
    this.cpuSeconds,
    this.rssBytes,
  });

  final int pid;
  final String? name;

  /// Processor seconds consumed **since the process started**, cumulative.
  final double? cpuSeconds;

  /// Resident set — `WorkingSet64` on Windows, `rss` × page size on Linux.
  final int? rssBytes;

  @override
  String toString() =>
      'ProcessReading($pid, $name, cpu=$cpuSeconds, rss=$rssBytes)';
}

/// What identifies a process as ours: who its parent is, and what it was run
/// with.
class ProcessIdentity {
  const ProcessIdentity({
    required this.pid,
    required this.parentPid,
    required this.commandLine,
  });

  final int pid;
  final int? parentPid;

  /// The whole command line, or null when it could not be read.
  ///
  /// Null is what refuses a process from the sample: a process we cannot
  /// describe is one we cannot claim.
  final String? commandLine;
}

/// One sample: every process read at one instant, with the wall clock at which
/// it was taken.
class ProcessSample {
  const ProcessSample({required this.at, required this.readings});

  final DateTime at;
  final List<ProcessReading> readings;
}

/// Which pids may be sampled, or why none may be.
class SamplingPlan {
  const SamplingPlan({required this.pids, required this.names, this.refusal});

  final List<int> pids;

  /// pid → the command line that proved it ours, for the table's own header.
  final Map<int, String> names;

  /// Set when nothing may be sampled. The run stops, in words.
  final String? refusal;
}

/// Reads processes from the host, per platform.
abstract class SystemProcessProbe {
  /// Every process's parentage and command line, as far as this user may see.
  ///
  /// An empty list means the table could not be read, which is a refusal and
  /// never an answer.
  Future<List<ProcessIdentity>> identities();

  /// CPU and resident set for exactly [pids].
  Future<List<ProcessReading>> read(List<int> pids);

  /// The probe for this host, or null on a platform this does not know.
  static Future<SystemProcessProbe?> forHost() async {
    if (Platform.isWindows) return const WindowsProcessProbe();
    if (Platform.isLinux) {
      return LinuxProcessProbe(clockTicks: await _clockTicks());
    }
    return null;
  }

  static Future<int> _clockTicks() async {
    try {
      final result = await Process.run('getconf', ['CLK_TCK']);
      final value = int.tryParse('${result.stdout}'.trim());
      if (value != null && value > 0) return value;
    } on ProcessException {
      // The POSIX default, and the value on every Linux this runs on.
    }
    return 100;
  }
}

/// `Get-Process` for the sample, `Get-CimInstance Win32_Process` for who is
/// whose child.
///
/// Two calls rather than one because they answer two different questions, and
/// only the first is on the sampling path: the identity table is read once,
/// before anything is sampled, and the per-sample call asks for named pids
/// alone.
class WindowsProcessProbe implements SystemProcessProbe {
  const WindowsProcessProbe();

  @override
  Future<List<ProcessIdentity>> identities() async {
    final csv = await _powerShell(
      'Get-CimInstance Win32_Process | '
      'Select-Object ProcessId,ParentProcessId,CommandLine | '
      'ConvertTo-Csv -NoTypeInformation',
    );
    return csv == null ? const [] : parseWin32ProcessCsv(csv);
  }

  @override
  Future<List<ProcessReading>> read(List<int> pids) async {
    if (pids.isEmpty) return const [];
    final csv = await _powerShell(
      'Get-Process -Id ${pids.join(',')} -ErrorAction SilentlyContinue | '
      'Select-Object Id,ProcessName,CPU,WorkingSet64 | '
      'ConvertTo-Csv -NoTypeInformation',
    );
    return fillMissing(pids, csv == null ? const [] : parseGetProcessCsv(csv));
  }

  /// **The output decides, not the exit code.** `Get-Process -Id` exits 1 the
  /// moment any one of the named pids has gone — `-ErrorAction
  /// SilentlyContinue` silences the message, not the status — and prints every
  /// process that *did* answer regardless. Measured on the owner's machine:
  /// exit 1, empty stderr, two complete rows. Reading the code as the verdict
  /// threw the whole sample away.
  static Future<String?> _powerShell(String script) async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      final out = '${result.stdout}';
      return out.trim().isEmpty ? null : out;
    } on ProcessException {
      return null;
    }
  }
}

/// `/proc`, read directly. No subprocess at all, which is what makes the
/// sampling cost of this harness itself close to nothing.
class LinuxProcessProbe implements SystemProcessProbe {
  LinuxProcessProbe({required this.clockTicks, this.pageSize = 4096});

  final int clockTicks;
  final int pageSize;

  @override
  Future<List<ProcessIdentity>> identities() async {
    final out = <ProcessIdentity>[];
    for (final entry in Directory('/proc').listSync()) {
      final pid = int.tryParse(entry.path.split('/').last);
      if (pid == null) continue;
      final stat = _readOrNull('/proc/$pid/stat');
      if (stat == null) continue;
      final fields = splitProcStat(stat);
      out.add(
        ProcessIdentity(
          pid: pid,
          parentPid: fields == null ? null : int.tryParse(fields.after[1]),
          // NUL-separated argv. Empty for a kernel thread, which is exactly the
          // process we must not claim.
          commandLine: _nullIfEmpty(
            _readOrNull('/proc/$pid/cmdline')?.replaceAll('\u0000', ' ').trim(),
          ),
        ),
      );
    }
    return out;
  }

  @override
  Future<List<ProcessReading>> read(List<int> pids) async => fillMissing(pids, [
    for (final pid in pids)
      ?parseProcStat(
        _readOrNull('/proc/$pid/stat') ?? '',
        pid: pid,
        clockTicks: clockTicks,
        pageSize: pageSize,
      ),
  ]);

  static String? _readOrNull(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      // A process that ended between the listing and the read, or one this
      // user may not see. Both are "we do not know", not zero.
      return null;
    }
  }
}

/// One row per requested pid, with unknowns for the ones that did not answer.
///
/// A process that has gone — or that this user may not open — must show as a
/// row of `?` rather than vanish from the table: a silently shorter sample is
/// a machine that looks cheaper than it was, which is the one direction a cost
/// measurement must not be wrong in.
List<ProcessReading> fillMissing(
  List<int> pids,
  List<ProcessReading> answered,
) {
  final byPid = {for (final reading in answered) reading.pid: reading};
  return [for (final pid in pids) byPid[pid] ?? ProcessReading(pid: pid)];
}

/// [value], or null when it is null or empty.
///
/// The empty string is what every one of these readers gets for a field the OS
/// declined to give it, and it must not travel any further as a value.
String? _nullIfEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

/// A `/proc/<pid>/stat` line split at the executable name.
///
/// The name is in parentheses and may itself contain spaces **and** closing
/// parentheses (`(dart (deleted))`), so the split is at the **last** `)` and
/// never at a field count from the left. Every parser that got this wrong read
/// the state character as a number.
class ProcStatFields {
  const ProcStatFields({required this.comm, required this.after});

  final String comm;

  /// The fields after the name, so `after[0]` is the state character — which
  /// makes `after[n]` the manual's field `n + 3`.
  final List<String> after;
}

ProcStatFields? splitProcStat(String line) {
  final close = line.lastIndexOf(')');
  final open = line.indexOf('(');
  if (close < 0 || open < 0 || close < open) return null;
  final after = line
      .substring(close + 1)
      .trim()
      .split(RegExp(r'\s+'))
      .where((field) => field.isNotEmpty)
      .toList();
  return ProcStatFields(comm: line.substring(open + 1, close), after: after);
}

/// One `/proc/<pid>/stat` line as a reading, or null when it is not one.
///
/// `utime` is the manual's field 14 and `stime` field 15, so they are
/// `after[11]` and `after[12]`; `rss` is field 24, so `after[21]`, and it is
/// counted in **pages**.
ProcessReading? parseProcStat(
  String line, {
  required int pid,
  required int clockTicks,
  required int pageSize,
}) {
  final fields = splitProcStat(line);
  if (fields == null || fields.after.length < 22) return null;
  final utime = int.tryParse(fields.after[11]);
  final stime = int.tryParse(fields.after[12]);
  final rss = int.tryParse(fields.after[21]);
  return ProcessReading(
    pid: pid,
    name: fields.comm,
    cpuSeconds: utime == null || stime == null
        ? null
        : (utime + stime) / clockTicks,
    rssBytes: rss == null ? null : rss * pageSize,
  );
}

/// `Get-Process | Select Id,ProcessName,CPU,WorkingSet64 | ConvertTo-Csv`.
///
/// An empty `CPU` cell is a real answer and stays null: PowerShell leaves it
/// empty for a process whose times this user may not read, and a zero there
/// would report a busy process as idle.
List<ProcessReading> parseGetProcessCsv(String csv) => _rows(csv)
    .map((row) {
      final pid = int.tryParse(row['Id'] ?? '');
      if (pid == null) return null;
      return ProcessReading(
        pid: pid,
        name: _nullIfEmpty(row['ProcessName']),
        cpuSeconds: double.tryParse((row['CPU'] ?? '').replaceAll(',', '')),
        rssBytes: int.tryParse(row['WorkingSet64'] ?? ''),
      );
    })
    .whereType<ProcessReading>()
    .toList();

/// `Get-CimInstance Win32_Process | Select ProcessId,ParentProcessId,CommandLine`.
List<ProcessIdentity> parseWin32ProcessCsv(String csv) => _rows(csv)
    .map((row) {
      final pid = int.tryParse(row['ProcessId'] ?? '');
      if (pid == null) return null;
      return ProcessIdentity(
        pid: pid,
        parentPid: int.tryParse(row['ParentProcessId'] ?? ''),
        commandLine: _nullIfEmpty(row['CommandLine']),
      );
    })
    .whereType<ProcessIdentity>()
    .toList();

/// `ConvertTo-Csv` output as maps keyed by its header row.
///
/// Written out rather than taken from a package because the shape is fixed and
/// tiny, and because the one thing that matters is the quoting: PowerShell
/// quotes every cell and doubles an embedded quote, and a command line is
/// exactly where a comma and a quote both turn up.
List<Map<String, String>> _rows(String csv) {
  final lines = csv
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length < 2) return const [];
  final header = splitCsvLine(lines.first);
  return [
    for (final line in lines.skip(1))
      if (splitCsvLine(line) case final cells
          when cells.length == header.length)
        {for (var i = 0; i < header.length; i++) header[i]: cells[i]},
  ];
}

/// One CSV line into cells, honouring quotes and doubled quotes inside them.
List<String> splitCsvLine(String line) {
  final cells = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quoted) {
      if (ch != '"') {
        buffer.write(ch);
      } else if (i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        quoted = false;
      }
      continue;
    }
    if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      cells.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  cells.add(buffer.toString());
  return cells;
}

/// [rootPid] and every process descended from it, per [identities].
///
/// Walks down from the root rather than up from a candidate, so a process is
/// included only when there is an unbroken chain of parents to something we
/// started. A cycle in a parentage table — pid reuse can produce one — is
/// bounded by the visited set rather than by a depth limit.
Set<int> descendantsOf(int rootPid, List<ProcessIdentity> identities) {
  final children = <int, List<int>>{};
  for (final identity in identities) {
    final parent = identity.parentPid;
    if (parent == null) continue;
    (children[parent] ??= []).add(identity.pid);
  }
  final found = <int>{rootPid};
  final queue = <int>[rootPid];
  while (queue.isNotEmpty) {
    for (final child in children[queue.removeLast()] ?? const <int>[]) {
      if (found.add(child)) queue.add(child);
    }
  }
  return found;
}

/// What may be sampled, given a parentage table — or the refusal.
///
/// Three refusals, and each is a different thing being unknown:
///
/// * **the table is empty** — nothing was read, so nothing can be claimed;
/// * **the root is not in it** — we cannot even find ourselves, so the table
///   is not describing this machine's processes;
/// * **a descendant has no command line** — a process we cannot describe is a
///   process we will not claim, and the run stops rather than dropping it
///   quietly, because a silently smaller sample reads as a cheaper one.
SamplingPlan planFor(int rootPid, List<ProcessIdentity> identities) {
  if (identities.isEmpty) {
    return const SamplingPlan(
      pids: [],
      names: {},
      refusal:
          'No process table could be read, so nothing here can be shown to be '
          'this app\'s. Refusing rather than sampling by process name.',
    );
  }
  final byPid = {for (final identity in identities) identity.pid: identity};
  if (!byPid.containsKey(rootPid)) {
    return SamplingPlan(
      pids: const [],
      names: const {},
      refusal:
          'The process table does not contain this process ($rootPid), so it '
          'is not describing this machine. Refusing.',
    );
  }
  final family = descendantsOf(rootPid, identities);
  final unnamed = [
    for (final pid in family)
      if (byPid[pid]?.commandLine == null) pid,
  ]..sort();
  if (unnamed.isNotEmpty) {
    return SamplingPlan(
      pids: const [],
      names: const {},
      refusal:
          'No command line could be read for ${unnamed.join(', ')}, so they '
          'cannot be shown to be this app\'s children. Refusing: a process '
          'this harness cannot describe is one it will not measure.',
    );
  }
  final pids = family.toList()..sort();
  return SamplingPlan(
    pids: pids,
    names: {for (final pid in pids) pid: byPid[pid]!.commandLine!},
  );
}

/// [planFor] against a table read from the host.
Future<SamplingPlan> planSampling(
  SystemProcessProbe probe, {
  required int rootPid,
}) async => planFor(rootPid, await probe.identities());

/// Takes [samples] readings of [pids], [interval] apart.
///
/// The one thing in this repository allowed to spend wall clock, and only by
/// hand: a rate is a quantity per unit time and there is no counting its way
/// around that. The gate counts work; this measures it.
Future<List<ProcessSample>> sample(
  SystemProcessProbe probe, {
  required List<int> pids,
  required int samples,
  required Duration interval,
  Future<void> Function(Duration)? wait,
}) async {
  final pause = wait ?? (delay) => Future<void>.delayed(delay);
  final taken = <ProcessSample>[];
  for (var i = 0; i < samples; i++) {
    if (i > 0) await pause(interval);
    taken.add(
      ProcessSample(at: DateTime.now(), readings: await probe.read(pids)),
    );
  }
  return taken;
}

/// The table: one row per process per sample, and the app's own among them.
///
/// [own] is the root of the tree — the app whose agents these are — and is
/// marked so the ratio everyone actually wants (what the agents cost *beside*
/// the thing that started them) can be read straight off the rows.
///
/// A percentage needs two readings, so the first sample of every process shows
/// `—` rather than `0.0%`. A field the OS withheld shows `?`.
String renderTable(
  List<ProcessSample> samples, {
  required int own,
  Map<int, String> named = const {},
}) {
  final out = StringBuffer();
  out.writeln('AGENT PROCESS COST — ${samples.length} samples');
  if (samples.isEmpty) {
    out.writeln('nothing was sampled.');
    return out.toString();
  }
  for (final entry in named.entries) {
    out.writeln(
      '  pid ${entry.key}${entry.key == own ? ' (the app itself)' : ''}: '
      '${_ellipsis(entry.value, 96)}',
    );
  }
  out.writeln('');
  out.writeln('  #  elapsed      pid  process           cpu%     rss');
  final previous = <int, ProcessReading>{};
  var previousAt = samples.first.at;
  for (var i = 0; i < samples.length; i++) {
    final sample = samples[i];
    final elapsed = sample.at.difference(samples.first.at);
    final window = sample.at.difference(previousAt);
    for (final reading in sample.readings) {
      out.writeln(
        '  ${_pad('$i', 2)} '
        '${_pad('${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s', 7)} '
        '${_pad('${reading.pid}', 8)} '
        '${_pad(reading.name ?? '?', 16)} '
        '${_pad(_percent(previous[reading.pid], reading, window), 7)} '
        '${_pad(_mib(reading.rssBytes), 9)}'
        '${reading.pid == own ? '  <- the app itself' : ''}',
      );
    }
    for (final reading in sample.readings) {
      previous[reading.pid] = reading;
    }
    previousAt = sample.at;
  }
  return out.toString();
}

String _percent(ProcessReading? before, ProcessReading now, Duration window) {
  final was = before?.cpuSeconds;
  final is_ = now.cpuSeconds;
  if (is_ == null) return '?';
  if (was == null || window.inMicroseconds <= 0) return '—';
  final share = (is_ - was) / (window.inMicroseconds / 1000000);
  return '${(share * 100).toStringAsFixed(1)}%';
}

String _mib(int? bytes) =>
    bytes == null ? '?' : '${(bytes / 1048576).toStringAsFixed(1)}M';

String _pad(String value, int width) =>
    value.length >= width ? value.substring(0, width) : value.padRight(width);

String _ellipsis(String value, int width) =>
    value.length <= width ? value : '${value.substring(0, width - 1)}…';
