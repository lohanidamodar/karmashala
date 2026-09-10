import 'package:agent_cli/process.dart';
import '../domain/android_device.dart';
import '../domain/android_slimming.dart';

/// Packages `pm list packages -d` reports as disabled. A line that is not
/// `package:<name>` is ignored, so an error on stdout is not read as a package.
Set<String> parseDisabledPackages(String stdout) {
  const prefix = 'package:';
  return {
    for (final line in stdout.split(RegExp(r'[\r\n]+')))
      if (line.trim().startsWith(prefix))
        if (line.trim().substring(prefix.length).trim() case final name
            when name.isNotEmpty)
          name,
  };
}

/// What one apply or restore run actually did. Neither half is an exception:
/// slimming must never be the reason a device fails to start.
class AndroidSlimmingReport {
  const AndroidSlimmingReport({
    this.applied = const [],
    this.failed = const {},
  });

  /// Subjects that changed — setting keys and package names.
  final List<String> applied;

  /// Subjects that did not, and the reason, keyed the same way.
  final Map<String, String> failed;

  bool get ok => failed.isEmpty;

  /// Whether anything at all was attempted. A run with nothing selected is not
  /// a failure; it is a user who asked for nothing.
  bool get isEmpty => applied.isEmpty && failed.isEmpty;

  @override
  String toString() =>
      'AndroidSlimmingReport(applied=${applied.length} '
      'failed=${failed.length}${failed.isEmpty ? '' : ' ${failed.keys.join(', ')}'})';
}

/// What an emulator currently carries from this build.
class AndroidSlimmingStatus {
  const AndroidSlimmingStatus({
    required this.serial,
    required this.disabledPackages,
    required this.settings,
  });

  final String serial;

  /// Every package the device reports as disabled, ours or not.
  final Set<String> disabledPackages;

  /// The managed `settings global` keys and their raw values. `null` is how
  /// `settings get` spells "unset", which is also the stock state.
  final Map<String, String?> settings;

  /// Disabled packages this build owns, and would put back.
  Set<String> get disabledManaged =>
      disabledPackages.intersection(allManagedPackages);

  /// Disabled packages somebody else turned off. [AndroidSlimmingService.restore]
  /// leaves these alone, and a UI should say so rather than claim stock.
  Set<String> get disabledUnmanaged =>
      disabledPackages.difference(allManagedPackages);

  /// The managed settings currently switched off — exactly what
  /// [AndroidSlimmingService.restore] would put back.
  Set<String> get slimmedSettings => {
    for (final entry in settings.entries)
      if (entry.value == '0') entry.key,
  };

  /// Whether any managed setting is switched off.
  bool get settingsSlimmed => slimmedSettings.isNotEmpty;

  /// Whether there is anything for [AndroidSlimmingService.restore] to do.
  bool get isSlimmed => disabledManaged.isNotEmpty || settingsSlimmed;

  /// One line describing what is on the device, for the Restore row. Counts
  /// rather than names, and the unmanaged tail is said out loud because Restore
  /// deliberately leaves it alone.
  String get summary {
    final left = disabledUnmanaged.isEmpty
        ? ''
        : ' ${_count(disabledUnmanaged.length, 'package')} something else '
              'disabled ${disabledUnmanaged.length == 1 ? 'is' : 'are'} left '
              'alone.';
    if (!isSlimmed) return 'Nothing this app applied is on it.$left';
    final applied = [
      if (settingsSlimmed) _count(slimmedSettings.length, 'setting'),
      if (disabledManaged.isNotEmpty)
        _count(disabledManaged.length, 'disabled package'),
    ];
    return 'This app has ${applied.join(' and ')} on it.$left';
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  @override
  String toString() =>
      'AndroidSlimmingStatus($serial settings=$settingsSlimmed '
      'packages=${disabledManaged.length}+${disabledUnmanaged.length})';
}

/// Applies the two durable slimming layers to a **booted** emulator; layer 1 is
/// emulator argv and belongs to `AdbService.bootAvd`. Nothing here throws —
/// every failure is recorded and the run carries on, because turning a saving
/// into an outage is the one unacceptable outcome.
class AndroidSlimmingService {
  AndroidSlimmingService({
    required this.runner,
    required this.sdk,
    this.bootTimeout = const Duration(minutes: 2),
    this.pollInterval = const Duration(seconds: 2),
  });

  final CommandRunner runner;
  final AndroidSdk sdk;

  /// How long [apply] waits for `sys.boot_completed`. A device that never gets
  /// there is reported, not slept through.
  final Duration bootTimeout;

  /// Gap between boot polls. Tests set it to zero.
  final Duration pollInterval;

  CommandRequest _adb(String serial, List<String> arguments) => CommandRequest(
    executable: sdk.adb.path,
    arguments: ['-s', serial, ...arguments],
  );

  /// Applies layers 2 and 3 for [enabled] to [serial]. Waits for
  /// `sys.boot_completed`: a device answers adb well before it has a package
  /// manager, and the first commands would fail in ways that look like our bug.
  Future<AndroidSlimmingReport> apply(
    String serial, {
    Set<AndroidSlimmingCategory> enabled = const {},
  }) async {
    final settings = settingsArguments(enabled: enabled);
    final packages = packagesFor(enabled: enabled);
    if (settings.isEmpty && packages.isEmpty) {
      return const AndroidSlimmingReport();
    }
    if (!await _awaitBoot(serial)) {
      return AndroidSlimmingReport(
        failed: {
          serial:
              'did not report sys.boot_completed within '
              '${bootTimeout.inSeconds}s, so nothing was changed',
        },
      );
    }

    final applied = <String>[];
    final failed = <String, String>{};
    // Both `settings put global <key> 0` and `settings delete global <key>`
    // carry the key at index 4; it is the subject a report names.
    for (final arguments in settings) {
      await _attempt(serial, arguments, arguments[4], applied, failed);
    }
    // Sorted so a run is reproducible and a test can assert the sequence; the
    // set that feeds this has no order of its own.
    for (final package in packages.toList()..sort()) {
      await _attempt(
        serial,
        disableArgumentsFor(package),
        package,
        applied,
        failed,
      );
    }
    return AndroidSlimmingReport(applied: applied, failed: failed);
  }

  /// Puts **everything this build manages** back on [serial] — not a mirror of
  /// the current selection, which would strand the setting nobody put back.
  /// Packages outside [allManagedPackages] are left disabled: not our decision.
  Future<AndroidSlimmingReport> restore(String serial) async {
    final applied = <String>[];
    final failed = <String, String>{};

    for (final arguments in settingsRestoreArguments()) {
      await _attempt(serial, arguments, arguments[4], applied, failed);
    }

    final status = await this.status(serial);
    for (final package in status.disabledManaged.toList()..sort()) {
      await _attempt(
        serial,
        enableArgumentsFor(package),
        package,
        applied,
        failed,
      );
    }
    return AndroidSlimmingReport(applied: applied, failed: failed);
  }

  /// What [serial] currently carries. Two commands, and safe on a device that
  /// was never slimmed.
  Future<AndroidSlimmingStatus> status(String serial) async {
    var disabled = const <String>{};
    final listed = await _runOrNull(serial, const [
      'shell',
      'pm',
      'list',
      'packages',
      '-d',
      '--user',
      '0',
    ]);
    if (listed != null) disabled = parseDisabledPackages(listed);

    final settings = <String, String?>{};
    for (final key in allManagedSettingsKeys) {
      final raw = await _runOrNull(serial, [
        'shell',
        'settings',
        'get',
        'global',
        key,
      ]);
      final value = raw?.trim();
      // `settings get` prints the literal `null` for a key that is not set,
      // which is the stock state and not a value.
      settings[key] = (value == null || value.isEmpty || value == 'null')
          ? null
          : value;
    }
    return AndroidSlimmingStatus(
      serial: serial,
      disabledPackages: disabled,
      settings: settings,
    );
  }

  /// Runs one command, recording the outcome against [subject]. Empty
  /// [arguments] means the allowlist refused the subject — a bug, not a device
  /// problem, so it is recorded and not run.
  Future<void> _attempt(
    String serial,
    List<String> arguments,
    String subject,
    List<String> applied,
    Map<String, String> failed,
  ) async {
    if (arguments.isEmpty) {
      failed[subject] = 'not a package this build manages';
      return;
    }
    try {
      final result = await runner.run(_adb(serial, arguments));
      if (result.ok) {
        applied.add(subject);
      } else {
        final message = result.stderr.trim().isEmpty
            ? result.stdout.trim()
            : result.stderr.trim();
        failed[subject] = message.isEmpty ? 'exit ${result.exitCode}' : message;
      }
    } on CommandException catch (error) {
      failed[subject] = error.message;
    }
  }

  Future<String?> _runOrNull(String serial, List<String> arguments) async {
    try {
      final result = await runner.run(_adb(serial, arguments));
      return result.ok ? result.stdout : null;
    } on CommandException {
      return null;
    }
  }

  /// Whether [serial] reaches `sys.boot_completed` inside [bootTimeout].
  Future<bool> _awaitBoot(String serial) async {
    final deadline = DateTime.now().add(bootTimeout);
    while (true) {
      final raw = await _runOrNull(serial, const [
        'shell',
        'getprop',
        'sys.boot_completed',
      ]);
      if (raw?.trim() == '1') return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      if (pollInterval > Duration.zero) {
        await Future<void>.delayed(pollInterval);
      }
    }
  }
}
