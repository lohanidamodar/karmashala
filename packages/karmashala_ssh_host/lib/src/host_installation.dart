part of 'host_deployer.dart';

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
    return after.after(
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
          : reading.after(
              'There is no session host on ${host.name} to start.',
            );
    }
    if (reading.running) {
      return reading.after(
        'The session host on ${host.name} is already running.',
      );
    }
    final started = await deployer._startServe(home, path);
    final greeting = started.ok ? await deployer._sayHello(path) : null;
    final after = (await _look()).reading;
    if (greeting == null) {
      return after.after(
        'The session host on ${host.name} would not start'
        '${started.output.isEmpty || started.ok ? '' : ': ${started.output}'}. '
        'Its log is $home/$kRemoteHomeSubdirectory/host.log on the machine.',
      );
    }
    return after.after(
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
          : found.reading.after(
              'No session host was running on ${host.name}.',
            );
    }
    final held = found.reading.sessionsHeld;
    final stopped = await deployer._stopServe(home);
    final after = (await _look()).reading;
    return after.after(
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
      return found.reading.after(
        '${relay.reason} The session host was left as it was.',
      );
    }
    final said = await deployer._stopServeSaid(home);
    if (said.contains('karmashala-still-running')) {
      return (await _look()).reading.after(
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
      return after.after(
        'The session host on ${host.name} is stopped, but its files in '
        '$directory/bin could not be deleted'
        '${removed.output.isEmpty ? '' : ' (${removed.output})'}.',
      );
    }
    return after.after(
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
    // Older than this app, and nothing newer to put there: no Update to offer.
    final noNewer =
        !outdated &&
        version != null &&
        compareHostVersions(version, kHostVersion) < 0 &&
        (binary == null || compareHostVersions(binary.version, version) <= 0);
    final folder =
        deployer.binaries.dropFolder ??
        'the host-bundles folder in the Karmashala server\'s data folder';
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
                  '${noNewer ? ' It is older than this app ($kHostVersion), and this build carries ${binary == null ? 'no host bundle' : 'no newer host'} for ${platform.targetKey}, so there is nothing to update it to. Rebuild or reinstall Karmashala with its host bundles, or put karmashala_host-$kHostVersion-${platform.targetKey}.tar.gz into $folder, then choose Check.' : ''}'
                  '${!noNewer && binary == null ? ' This build carries no bundle for ${platform.targetKey}, so it cannot update or reinstall it.' : ''}',
        noNewerHost: noNewer,
      ),
      home: home,
    );
  }

  static bool _isNewer(String? installed, String offered) =>
      installed != null &&
      compareHostVersions(installed, offered) > 0;

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
    return compareHostVersions(b.version, a.version);
  }
}
