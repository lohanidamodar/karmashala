part of 'host_deployer.dart';

/// Where one machine's session host stands, as a person would say it.
enum HostInstallState {
  /// Nothing of ours is on the machine, and this build has a bundle for it.
  notInstalled,

  /// This build's host — or, when this build carries none, some host — is
  /// installed. Running or stopped is a second fact.
  installed,

  /// A host from another app version is what is installed or running.
  outdated,

  /// Nothing is installed and nothing can be: no bundle for the machine, or a
  /// machine the host does not run on.
  cannotInstall,

  /// The machine could not be asked. A missing reading, not a negative one.
  unknown,
}

/// One reading of one machine's session host, with the time it was taken.
/// Taken when somebody asks and after each action — never on a timer (§19).
@immutable
class HostInstallReading {
  const HostInstallReading({
    required this.state,
    required this.observedAt,
    required this.reason,
    this.platform,
    this.installedVersion,
    this.offeredVersion,
    this.running = false,
    this.sessionsHeld,
    this.remotePath,
    this.deployment,
    this.availableTargets = const [],
  });

  final HostInstallState state;
  final DateTime observedAt;

  /// One sentence: what was found, or what the last action did.
  final String reason;

  final HostPlatform? platform;

  /// The version in effect on the machine: the running one, else this build's
  /// when it is there, else the newest installed. From the filename.
  final String? installedVersion;

  /// The version this build would install, or null when it carries no bundle
  /// for the machine.
  final String? offeredVersion;

  final bool running;

  /// How many sessions the running host holds; null when it is not running or
  /// would not say. Stop and Remove end them.
  final int? sessionsHeld;

  /// The executable in effect, which Start runs.
  final String? remotePath;

  /// The deploy this reading followed, when one ran and did not end ready —
  /// what `explainHostDeployment` turns into a sentence and a remedy.
  final HostDeployment? deployment;

  final List<String> availableTargets;

  bool get canInstall => offeredVersion != null;

  /// Whether what is on the machine is a *later* build than this app carries —
  /// a downgraded app, or a second desktop ahead of this one. Installing this
  /// app's is then not an update, and is not called one.
  bool get hostIsNewer =>
      state == HostInstallState.outdated &&
      installedVersion != null &&
      offeredVersion != null &&
      DirectoryHostBinaries.compareFilenameVersions(
            installedVersion,
            offeredVersion,
          ) >
          0;

  /// `installed 1.25.0 (running)` — what follows "Karmashala host:".
  String get label => switch (state) {
    HostInstallState.notInstalled => 'not installed',
    HostInstallState.installed =>
      'installed ${installedVersion ?? 'unversioned'} '
          '(${running ? 'running' : 'stopped'})',
    HostInstallState.outdated when hostIsNewer =>
      'newer than this app ($installedVersion; this app carries '
          '$offeredVersion), ${running ? 'running' : 'stopped'}',
    HostInstallState.outdated =>
      'older than this app (${installedVersion ?? 'unversioned'} → '
          '${offeredVersion ?? 'unknown'}), ${running ? 'running' : 'stopped'}',
    HostInstallState.cannotInstall => 'can\'t install: $reason',
    HostInstallState.unknown => 'unknown: $reason',
  };

  HostInstallReading _after(String said, {HostDeployment? deployment}) =>
      HostInstallReading(
        state: state,
        observedAt: observedAt,
        reason: said,
        platform: platform,
        installedVersion: installedVersion,
        offeredVersion: offeredVersion,
        running: running,
        sessionsHeld: sessionsHeld,
        remotePath: remotePath,
        deployment: deployment,
        availableTargets: availableTargets,
      );
}

/// The explicit verbs on one machine's session host: look, install, start,
/// stop, remove. Installing **is** [HostDeployer.deploy] — the same arch pick,
/// size check and unpack a pane's implicit deploy runs — so there is one
/// implementation, and everything lands under the remote home: no root.
class HostInstaller {
  HostInstaller({required this.host, required this.deployer});

  final SshHost host;
  final HostDeployer deployer;

  HostDeployTarget get _target => deployer.target;

  static final _entry = RegExp(
    r'^karmashala_host-(?:([0-9][^-]*)-)?([a-z]+)-([a-z0-9]+)(\.d)?$',
  );

  /// Reads, and changes nothing on the machine.
  Future<HostInstallReading> check() async {
    final found = await _look();
    return found.reading;
  }

  /// Install, Update and Reinstall are one deploy; [reinstall] uploads again
  /// over what is there.
  Future<HostInstallReading> install({bool reinstall = false}) async {
    final deployment = await deployer.deploy(reinstall: reinstall);
    final after = (await _look()).reading;
    return after._after(
      deployment.reason,
      deployment: deployment.isReady ? null : deployment,
    );
  }

  Future<HostInstallReading> start() async {
    final found = await _look();
    final reading = found.reading;
    final home = found.home;
    final path = reading.remotePath;
    if (home == null || path == null) {
      return reading.state == HostInstallState.unknown
          ? reading
          : reading._after(
              'There is no session host on ${host.name} to start.',
            );
    }
    if (reading.running) {
      return reading._after(
        'The session host on ${host.name} is already running.',
      );
    }
    final started = await deployer._startServe(home, path);
    final greeting = started.ok ? await deployer._sayHello(path) : null;
    final after = (await _look()).reading;
    if (greeting == null) {
      return after._after(
        'The session host on ${host.name} would not start'
        '${started.output.isEmpty || started.ok ? '' : ': ${started.output}'}. '
        'Its log is $home/$kRemoteHomeSubdirectory/host.log on the machine.',
      );
    }
    return after._after(
      'Started the session host on ${host.name}. It does not come back by '
      'itself after the machine restarts; Start, or the next pane there, '
      'brings it back.',
    );
  }

  /// Ends every session the host holds — the caller asks first.
  Future<HostInstallReading> stop() async {
    final found = await _look();
    final home = found.home;
    if (home == null || !found.reading.running) {
      return found.reading.state == HostInstallState.unknown
          ? found.reading
          : found.reading._after(
              'No session host was running on ${host.name}.',
            );
    }
    final held = found.reading.sessionsHeld;
    final stopped = await deployer._stopServe(home);
    final after = (await _look()).reading;
    return after._after(
      stopped
          ? 'Stopped the session host on ${host.name}.'
                '${held != null && held > 0 ? ' The $held session(s) it held have ended.' : ''}'
          : 'The session host on ${host.name} would not stop. Nothing else '
                'was changed.',
    );
  }

  /// Stops the relay and the host, then deletes every bundle and the files
  /// either wrote. Recorded sessions and the store of paired phones stay.
  Future<HostInstallReading> remove() async {
    final found = await _look();
    final home = found.home;
    if (home == null) return found.reading;
    final directory = '$home/$kRemoteHomeSubdirectory';

    final relay = await SshRelaySetup(
      host: host,
      target: _target,
      remotePath: found.reading.remotePath ?? '',
    ).remove();
    if (relay.status != SshRelayStatus.stopped) {
      return found.reading._after(
        '${relay.reason} The session host was left as it was.',
      );
    }
    final said = await deployer._stopServeSaid(home);
    if (said.contains('karmashala-still-running')) {
      return (await _look()).reading._after(
        'The relay on ${host.name} was removed, but the session host would '
        'not stop, so its files were left in place.',
      );
    }
    final q = HostDeployer._quote;
    final removed = await _target.run(
      'rm -rf ${q('$directory/bin')}/karmashala_host-* && '
      'rm -f ${q('$directory/host.log')} ${q('$directory/host.lock')} '
      '${q('$directory/host.sock')}; '
      'r="\${XDG_RUNTIME_DIR:+\$XDG_RUNTIME_DIR/karmashala}"; '
      '[ -n "\$r" ] && rm -f "\$r/host.lock" "\$r/host.sock"; '
      'rmdir ${q('$directory/bin')} 2>/dev/null; echo karmashala-removed',
    );
    final after = (await _look()).reading;
    if (!removed.stdout.contains('karmashala-removed')) {
      return after._after(
        'The session host on ${host.name} is stopped, but its files in '
        '$directory/bin could not be deleted'
        '${removed.output.isEmpty ? '' : ' (${removed.output})'}.',
      );
    }
    return after._after(
      'Removed the session host from ${host.name}: its bundles, log and lock, '
      'and the relay\'s token, pid and log. Left in place: '
      '$directory/sessions (recorded output) and the store of phones paired '
      'with this machine — delete $directory there to remove those too.',
    );
  }

  Future<({HostInstallReading reading, String? home})> _look() async {
    final now = deployer._now;
    final HostPlatform? platform;
    try {
      platform = await deployer.measurePlatform();
    } on Object catch (error) {
      return (
        reading: HostInstallReading(
          state: HostInstallState.unknown,
          observedAt: now(),
          reason: '${host.name} could not be asked ($error).',
        ),
        home: null,
      );
    }
    if (platform == null) {
      return (
        reading: HostInstallReading(
          state: HostInstallState.unknown,
          observedAt: now(),
          reason: '${host.name} did not answer `uname -sm`.',
        ),
        home: null,
      );
    }
    final home = await deployer.resolveHome();
    if (home == null) {
      return (
        reading: HostInstallReading(
          state: HostInstallState.unknown,
          observedAt: now(),
          platform: platform,
          reason:
              '${host.name} did not answer `echo "\$HOME"` with an absolute path.',
        ),
        home: null,
      );
    }

    final bin = '$home/$kRemoteHomeSubdirectory/bin';
    final listing = await _target.run(
      'for f in ${HostDeployer._quote(bin)}/karmashala_host-*; do '
      '[ -e "\$f" ] || continue; n="\${f##*/}"; '
      'case "\$n" in *.tar.gz) continue;; '
      '*.d) [ -x "\$f/bin/karmashala_host" ] && echo "installed=\$n";; '
      '*) [ -x "\$f" ] && echo "installed=\$n";; esac; done; echo karmashala-listed',
    );
    if (!listing.stdout.contains('karmashala-listed')) {
      return (
        reading: HostInstallReading(
          state: HostInstallState.unknown,
          observedAt: now(),
          platform: platform,
          reason:
              '${host.name} would not list $bin'
              '${listing.output.isEmpty ? '' : ' (${listing.output})'}.',
        ),
        home: home,
      );
    }
    final entries = <_Installed>[
      for (final line in const LineSplitter().convert(listing.stdout))
        if (line.startsWith('installed='))
          if (_entry.firstMatch(line.substring(10).trim()) case final match?)
            _Installed(
              name: match.group(0)!,
              version: match.group(1),
              isBundle: match.group(4) != null,
              directory: bin,
            ),
    ]..sort(_Installed.newestFirst);

    final refusal = deployer._unsupported(platform);
    final binary = refusal == null
        ? await deployer.binaries.binaryFor(platform)
        : null;
    final targets = await deployer.binaries.availableTargets();
    final offered = binary == null
        ? null
        : _RemoteLayout.of(bin, binary, platform).executable;

    final runningPath = await deployer._runningServePath(home);
    final running = runningPath != null;
    final held = running ? await deployer._sessionsHeld(runningPath) : null;

    if (entries.isEmpty && !running) {
      if (binary != null) {
        return (
          reading: HostInstallReading(
            state: HostInstallState.notInstalled,
            observedAt: now(),
            platform: platform,
            offeredVersion: binary.version,
            availableTargets: targets,
            reason:
                'Nothing of Karmashala\'s is on ${host.name} yet. Install puts '
                'the session host under $home/$kRemoteHomeSubdirectory — no '
                'root needed — and it is also put there the first time a pane, '
                'a relay or a phone pairing needs it.',
          ),
          home: home,
        );
      }
      final why = refusal ?? await deployer._noBinary(platform);
      return (
        reading: HostInstallReading(
          state: HostInstallState.cannotInstall,
          observedAt: now(),
          platform: platform,
          availableTargets: targets,
          deployment: why,
          reason: why.reason,
        ),
        home: home,
      );
    }

    final ours = entries.where((e) => e.executable == offered).firstOrNull;
    final inEffect = running
        ? runningPath
        : (ours ?? entries.firstOrNull)?.executable;
    final version = _versionOf(inEffect);
    final outdated = offered != null && inEffect != offered;
    final where = running ? 'running' : 'installed and not running';
    return (
      reading: HostInstallReading(
        state: outdated
            ? HostInstallState.outdated
            : HostInstallState.installed,
        observedAt: now(),
        platform: platform,
        installedVersion: version,
        offeredVersion: binary?.version,
        running: running,
        sessionsHeld: held,
        remotePath: inEffect,
        availableTargets: targets,
        reason: outdated
            ? 'The session host on ${host.name} is ${version ?? 'unversioned'}, '
                  '$where; this app carries ${binary!.version}. '
                  '${_isNewer(version, binary.version) ? 'A later build put it there. Installing this app\'s puts ${binary.version} beside it' : 'Update installs it beside the old one'} '
                  'and moves over when the running one holds no sessions.'
            : 'The session host ${version ?? 'unversioned'} on ${host.name} is '
                  '$where'
                  '${held == null || held == 0 ? '' : ', holding $held session(s)'}.'
                  '${binary == null ? ' This build carries no bundle for ${platform.targetKey}, so it cannot update or reinstall it.' : ''}',
      ),
      home: home,
    );
  }

  static bool _isNewer(String? installed, String offered) =>
      installed != null &&
      DirectoryHostBinaries.compareFilenameVersions(installed, offered) > 0;

  /// `1.25.0` out of `…/karmashala_host-1.25.0-linux-x64.d/bin/karmashala_host`.
  static String? _versionOf(String? path) {
    if (path == null) return null;
    for (final segment in path.split('/')) {
      final match = _entry.firstMatch(segment);
      if (match != null) return match.group(1);
    }
    return null;
  }
}

class _Installed {
  const _Installed({
    required this.name,
    required this.version,
    required this.isBundle,
    required this.directory,
  });

  final String name;
  final String? version;
  final bool isBundle;
  final String directory;

  String get executable =>
      isBundle ? '$directory/$name/bin/karmashala_host' : '$directory/$name';

  /// Bundles before bare files, then the higher version — the order
  /// [DirectoryHostBinaries] picks in, for the same reason.
  static int newestFirst(_Installed a, _Installed b) {
    final byShape = (b.isBundle ? 1 : 0) - (a.isBundle ? 1 : 0);
    if (byShape != 0) return byShape;
    return DirectoryHostBinaries.compareFilenameVersions(b.version, a.version);
  }
}
