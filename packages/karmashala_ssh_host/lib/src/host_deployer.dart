import 'dart:async';
import 'dart:convert';

import 'package:karmashala_host/protocol.dart';
import 'package:meta/meta.dart';

import 'package:karmashala_core/logging.dart';
import 'host_deployment.dart';
import 'host_binaries.dart';
import 'host_deploy_target.dart';
import 'privileged_command.dart';
import 'relay_setup.dart';
import 'remote_detach.dart';
import 'remote_home.dart';
import 'package:karmashala_ssh/connection.dart';

part 'host_installation.dart';

/// Puts the session host on a machine and confirms it answers. Every outcome
/// carries when it was taken — a host that answered is not one that answers.
class HostDeployer {
  HostDeployer({
    required this.target,
    required this.binaries,
    DateTime Function()? clock,
    AppLogger? logger,
    this.helloTimeout = const Duration(seconds: 15),
  }) : _now = clock ?? DateTime.now,
       _logger = logger ?? AppLogger.named('ssh.host');

  final HostDeployTarget target;
  final HostBinarySource binaries;

  /// How long to wait for a `hello` to come back. A bound on an answer over a
  /// network, not a poll — nothing asks twice.
  final Duration helloTimeout;
  final DateTime Function() _now;
  final AppLogger _logger;

  /// What is hung off the remote home. A *fragment*, never a path: `mkdir`
  /// expands `$HOME`, SFTP does not, so a literal `$HOME/...` names nothing.
  static const String remoteHomeSubdirectory = kRemoteHomeSubdirectory;

  /// [reinstall] uploads and unpacks again whatever is already there, and
  /// restarts a `serve` running from it when that holds no sessions.
  Future<HostDeployment> deploy({bool reinstall = false}) async {
    final platform = await measurePlatform();
    if (platform == null) {
      return HostDeployment.unknown(
        '${target.address} did not answer `uname -sm`.',
        _now(),
      );
    }
    final unsupported = _unsupported(platform);
    if (unsupported != null) return unsupported;

    final binary = await binaries.binaryFor(platform);
    if (binary == null) return _noBinary(platform);
    _logger.debug(
      'host binary for ${platform.targetKey}: ${binary.source} (version ${binary.version}, '
      '${binary.candidates == 1 ? 'the only candidate' : 'newest of ${binary.candidates} candidates'}).',
    );

    // One reading, before any path is spelled. Everything below is built from
    // it, so nothing this deploy writes can depend on who expands what.
    final home = await resolveHome();
    if (home == null) {
      return HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: _now(),
        platform: platform,
        reason:
            '${target.address} did not answer `echo "\$HOME"` with an absolute path, so '
            'there is nowhere here to put the host. Nothing was uploaded.',
      );
    }
    final remoteDirectory = '$home/$remoteHomeSubdirectory/bin';
    final layout = _RemoteLayout.of(remoteDirectory, binary, platform);
    final remotePath = layout.executable;
    try {
      await _install(remoteDirectory, layout, binary, force: reinstall);
    } on HostInstallException catch (e) {
      return HostDeployment(
        status: HostDeploymentStatus.cannotInstall,
        observedAt: _now(),
        platform: platform,
        remotePath: remotePath,
        reason: e.message,
        privileged: e.privileged,
      );
    }

    var greeting = await _sayHello(remotePath);
    // A host that had to be started is a host that was not running, and its
    // earlier sessions are gone. The caller has to be able to say so.
    var restarted = false;
    if (greeting == null) {
      restarted = true;
      final started = await _startServe(home, remotePath);
      if (!started.ok) {
        return HostDeployment(
          status: HostDeploymentStatus.cannotStart,
          observedAt: _now(),
          platform: platform,
          remotePath: remotePath,
          reason:
              '`$remotePath serve` would not start on ${target.address}: '
              '${started.output.isEmpty ? 'no output, exit ${started.exitCode}' : started.output}',
          restartedByUs: true,
        );
      }
      greeting = await _sayHello(remotePath);
    }
    if (greeting == null) {
      return HostDeployment(
        status: HostDeploymentStatus.cannotStart,
        observedAt: _now(),
        platform: platform,
        remotePath: remotePath,
        reason:
            'The host on ${target.address} was installed and started but never answered `hello`.',
        restartedByUs: true,
      );
    }
    if (greeting.protocolVersion != kProtocolVersion) {
      return HostDeployment(
        status: HostDeploymentStatus.protocolMismatch,
        observedAt: _now(),
        platform: platform,
        remotePath: remotePath,
        hostVersion: greeting.hostVersion,
        protocolVersion: greeting.protocolVersion,
        reason:
            'The host on ${target.address} speaks protocol ${greeting.protocolVersion}; '
            'this app speaks $kProtocolVersion. A stale `serve` is probably still running.',
        restartedByUs: restarted,
      );
    }
    // A `serve` already running answers `hello` whatever binary started it, and
    // the protocol check above passes while the protocol holds — so a machine
    // keeps the first host it was ever given until something replaces it.
    // **Not** a version comparison: `hostVersion` is the host package's own
    // constant and is the same string in every build, while the app's version
    // is only in the filename. What identifies a build is the path it runs
    // from. Replacing one costs every session it holds, so it is replaced only
    // when it holds none.
    var stale = '';
    final runningPath = restarted ? null : await _runningServePath(home);
    // The files under a running `serve` were just replaced; it goes on running
    // the old ones until it is started again, which costs what it holds.
    if (reinstall && runningPath == remotePath) {
      final held = await _sessionsHeld(remotePath);
      if (held == 0 && await _stopServe(home)) {
        final started = await _startServe(home, remotePath);
        final fresh = started.ok ? await _sayHello(remotePath) : null;
        if (fresh != null) {
          greeting = fresh;
          restarted = true;
        }
      }
      if (!restarted) {
        stale = held == null || held == 0
            ? ' It was reinstalled, and the running host could not be '
                  'restarted onto the fresh files.'
            : ' It was reinstalled; $held session(s) are on the running host, '
                  'so it was left running and uses the fresh files the next '
                  'time it starts.';
      }
    }
    if (runningPath != null && runningPath != remotePath) {
      final held = await _sessionsHeld(remotePath);
      if (held == 0 && await _stopServe(home)) {
        final started = await _startServe(home, remotePath);
        final fresh = started.ok ? await _sayHello(remotePath) : null;
        if (fresh != null) {
          greeting = fresh;
          restarted = true;
        }
      }
      if (!restarted) {
        final was = runningPath.split('/').last;
        stale = held == null
            ? ' It is running $was and would not say what it holds, so '
                  '${binary.version} was left installed beside it.'
            : held == 0
            ? ' It is running $was and could not be replaced with '
                  '${binary.version}.'
            : ' It is running $was; ${binary.version} is installed beside it, '
                  'and $held session(s) are on the old one, so it was left '
                  'alone.';
      }
    }
    return HostDeployment(
      status: HostDeploymentStatus.ready,
      observedAt: _now(),
      platform: platform,
      remotePath: remotePath,
      hostVersion: greeting.hostVersion,
      protocolVersion: greeting.protocolVersion,
      restartedByUs: restarted,
      reason:
          'karmashala_host ${greeting.hostVersion} answering on ${target.address} '
          '(${platform.targetKey}, ${greeting.ptyLibrary}).'
          '${restarted ? ' It was not running and has been restarted, so any sessions it held before are gone.' : ''}'
          '$stale',
    );
  }

  /// Null for a machine the host runs on; otherwise why it does not.
  HostDeployment? _unsupported(HostPlatform platform) {
    if (platform.libc == HostLibc.musl) {
      return HostDeployment(
        status: HostDeploymentStatus.unsupportedPlatform,
        observedAt: _now(),
        platform: platform,
        reason:
            '${target.address} runs musl libc. The host bundles are glibc-linked ELF, '
            'so there is nothing to send.',
      );
    }
    if (platform.isLinux || platform.isDarwin) return null;
    return HostDeployment(
      status: HostDeploymentStatus.unsupportedPlatform,
      observedAt: _now(),
      platform: platform,
      reason:
          '${target.address} runs ${platform.operatingSystem}; the host is published for '
          'Linux and macOS only.',
    );
  }

  Future<HostDeployment> _noBinary(HostPlatform platform) async {
    final have = await binaries.availableTargets();
    return HostDeployment(
      status: HostDeploymentStatus.noBinary,
      observedAt: _now(),
      platform: platform,
      availableTargets: have,
      reason:
          'No host binary for ${platform.targetKey} in this build'
          '${have.isEmpty ? '' : ' (it has ${have.join(', ')})'}.',
    );
  }

  /// `uname -sm` plus a libc reading, in one command so it costs one channel.
  Future<HostPlatform?> measurePlatform() async {
    final result = await target.run(
      // `ldd --version` writes to stderr on some builds and stdout on others,
      // and Alpine's exits non-zero; the redirect and `|| true` survive both.
      'uname -s; uname -m; (ldd --version 2>&1 || true) | head -1',
    );
    final lines = const LineSplitter()
        .convert(result.stdout)
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final libcLine = (lines.length > 2 ? lines[2] : '').toLowerCase();
    return HostPlatform(
      operatingSystem: lines[0].toLowerCase(),
      architecture: HostPlatform.normaliseArchitecture(lines[1]),
      libc: libcLine.contains('musl')
          ? HostLibc.musl
          : libcLine.contains('glibc') || libcLine.contains('gnu libc')
          ? HostLibc.glibc
          // Not "glibc by default": a machine that did not say is one we do not
          // know about, worth trying while being reported as unknown.
          : HostLibc.unknown,
      observedAt: _now(),
    );
  }

  /// The remote home as an absolute path, asked of the machine's shell. Null is
  /// *unknown*, never a guess at `/home/<user>`; the last non-empty line wins.
  Future<String?> resolveHome() => resolveRemoteHome(target, logger: _logger);

  /// Uploads unless what is already there is this size. Size, not a checksum:
  /// the version is in the filename, and hashing megabytes per open costs more.
  /// For a bundle the size measured is the *uploaded archive's*, which is still
  /// beside the directory it was unpacked into for exactly this reason.
  Future<void> _install(
    String remoteDirectory,
    _RemoteLayout layout,
    HostBinary binary, {
    bool force = false,
  }) async {
    final existing = await target.run(
      'mkdir -p ${_quote(remoteDirectory)} && wc -c < ${_quote(layout.upload)} 2>/dev/null || echo missing',
    );
    final reported = existing.stdout.trim();
    // The right size does not mean it can run: for a bundle nothing may have
    // unpacked the archive, and a bare file restored from a backup is the size
    // it should be and is not executable.
    if (!force &&
        reported == '${binary.length}' &&
        await _isRunnable(layout.executable)) {
      _logger.debug(
        '${layout.upload} is already ${binary.length} bytes; skipping the upload.',
      );
      return;
    }
    if (!existing.ok && reported != 'missing') {
      throw HostInstallException(
        'Could not reach $remoteDirectory on ${target.address}: ${existing.output}',
      );
    }
    // Asked before tens of megabytes cross the wire for a machine that cannot
    // unpack or start them.
    await _requireTools(archive: layout.unpackInto != null);
    try {
      // Read only now. The skip above is the steady state, and these bytes are
      // a whole bundle.
      await target.upload(layout.upload, await binary.readBytes());
    } on Object catch (e) {
      throw HostInstallException(
        'Could not write ${layout.upload} on ${target.address} ($e). A read-only home '
        'directory or a full disk would look like this.',
      );
    }
    final unpackInto = layout.unpackInto;
    if (unpackInto != null) await _unpack(layout.upload, unpackInto);
    final chmod = await target.run(
      'chmod +x ${_quote(layout.executable)} && test -x ${_quote(layout.executable)}',
    );
    if (!chmod.ok) {
      throw HostInstallException(
        '${layout.executable} was uploaded to ${target.address} but cannot be executed '
        '(${chmod.output.isEmpty ? 'exit ${chmod.exitCode}' : chmod.output}). '
        'A noexec home directory looks like this.',
      );
    }
  }

  /// `tar` unpacks the bundle and `setsid` — or perl, on a Mac — detaches
  /// `serve`; a minimal image can lack either. Installing a package is root's, so it becomes a command
  /// for a terminal there rather than something attempted from here.
  Future<void> _requireTools({required bool archive}) async {
    final tools = [if (archive) 'tar', 'setsid'];
    final result = await target.run(
      // perl stands in for setsid (macOS has none): see [detachedStart].
      'for t in ${tools.join(' ')}; do '
      'case "\$t" in setsid) $kCanDetachTest && continue;; esac; '
      'command -v "\$t" >/dev/null 2>&1 || echo "missing=\$t"; done; '
      'for m in apt-get dnf yum pacman zypper; do '
      'if command -v "\$m" >/dev/null 2>&1; then echo "pm=\$m"; break; fi; done; '
      'echo "uid=\$(id -u 2>/dev/null)"',
    );
    final lines = const LineSplitter()
        .convert(result.stdout)
        .map((l) => l.trim())
        .toList();
    final missing = [
      for (final line in lines)
        if (line.startsWith('missing=')) line.substring(8),
    ];
    if (missing.isEmpty) return;
    String? said(String key) {
      for (final line in lines) {
        if (line.startsWith('$key=')) return line.substring(key.length + 1);
      }
      return null;
    }

    final packages = {
      for (final tool in missing) tool == 'setsid' ? 'util-linux' : tool,
    }.join(' ');
    final sudo = said('uid') == '0' ? '' : 'sudo ';
    final install = switch (said('pm')) {
      'apt-get' => '${sudo}apt-get install -y $packages',
      'dnf' => '${sudo}dnf install -y $packages',
      'yum' => '${sudo}yum install -y $packages',
      'pacman' => '${sudo}pacman -S --needed $packages',
      'zypper' => '${sudo}zypper install -y $packages',
      _ => null,
    };
    final names = missing.map((t) => '`$t`').join(' and ');
    throw HostInstallException(
      '${target.address} has no $names, which the session host needs to '
      '${missing.contains('tar') ? 'be unpacked' : 'keep running after this connection closes'}. '
      'Nothing was uploaded.'
      '${install == null ? ' Install $packages with the machine\'s package manager, then install again.' : ''}',
      privileged: install == null
          ? null
          : PrivilegedCommand(
              command: install,
              does:
                  'Installs $packages on ${target.address} from its own package manager.',
              why:
                  'Installing a system package changes the whole machine and needs '
                  'root, so it is yours to run, in a terminal there.',
            ),
    );
  }

  /// Whether what is already on the machine can run. The `chmod` rides along
  /// rather than costing a second round trip, and is allowed to fail — the
  /// `test -x` is the answer.
  Future<bool> _isRunnable(String path) async => (await target.run(
    'chmod +x ${_quote(path)} 2>/dev/null; test -x ${_quote(path)}',
  )).ok;

  /// Unpacks the bundle into a directory of its own, replacing whatever was
  /// there: a half-extracted tree from an interrupted deploy is the one state
  /// that would otherwise survive and look installed.
  Future<void> _unpack(String archivePath, String into) async {
    final result = await target.run(
      'rm -rf ${_quote(into)} && mkdir -p ${_quote(into)} && '
      'tar -xzf ${_quote(archivePath)} -C ${_quote(into)}',
    );
    if (!result.ok) {
      throw HostInstallException(
        'Could not unpack $archivePath on ${target.address} '
        '(${result.output.isEmpty ? 'exit ${result.exitCode}' : result.output}). '
        'A machine with no `tar` looks like this.',
      );
    }
  }

  /// Runs `attach` and completes the handshake — the only proof that matters,
  /// since a file being present is not a host answering.
  Future<HostGreeting?> _sayHello(String remotePath) async {
    RemoteChannel? channel;
    try {
      // Unquoted, exactly as the pane spells it: the two must run the same
      // command, and the pane's is the one a user sees in the notice.
      channel = await target.exec('$remotePath attach');
      final parser = FrameParser();
      final greeting = Completer<HostGreeting?>();
      final subscription = channel.stdout.listen((chunk) {
        if (greeting.isCompleted) return;
        final List<Frame> frames;
        try {
          frames = parser.add(chunk);
        } on Object catch (e) {
          greeting.completeError(e); // Answered now, not after the hello bound.
          return;
        }
        for (final frame in frames) {
          final HostMessage message;
          try {
            message = decodeMessage(frame);
          } on Object catch (e) {
            greeting.completeError(e);
            return;
          }
          if (message is WelcomeMessage) {
            greeting.complete(
              HostGreeting(
                hostVersion: message.hostVersion,
                protocolVersion: message.protocolVersion,
                ptyLibrary: message.ptyLibrary,
              ),
            );
            return;
          }
          if (message is ErrorMessage) {
            greeting.complete(_greetingFromRefusal(message));
            return;
          }
        }
      }, onError: (Object _) {});
      channel.add(
        const HelloMessage(
          requestId: 1,
          clientId: 'karmashala-deployer',
        ).toFrame().encode(),
      );
      try {
        return await greeting.future.timeout(helloTimeout);
      } finally {
        await subscription.cancel();
      }
    } on TimeoutException {
      return null;
    } on Object catch (e) {
      _logger.debug('hello on ${target.address} failed: $e');
      return null;
    } finally {
      await channel?.close();
    }
  }

  /// The host's own words carry its version. Quoted back, never guessed: a
  /// changed wording then reports an unknown version rather than a wrong one.
  static HostGreeting? _greetingFromRefusal(ErrorMessage refusal) {
    if (refusal.code != ProtocolErrorCode.protocolMismatch) return null;
    final match = RegExp(
      r'host speaks protocol (\d+)',
    ).firstMatch(refusal.message);
    return HostGreeting(
      hostVersion: 'unknown',
      protocolVersion: match == null ? -1 : int.parse(match.group(1)!),
      ptyLibrary: 'unknown',
    );
  }

  /// Detached ([detachedStart]), so the daemon leaves this channel's process
  /// group before it closes; output goes to a log, which would hold the
  /// channel open.
  /// How many sessions the running host holds, or null when it would not say.
  /// Zero is the only answer that makes replacing it safe.
  Future<int?> _sessionsHeld(String remotePath) async {
    RemoteChannel? channel;
    try {
      channel = await target.exec('$remotePath attach');
      final parser = FrameParser();
      final counted = Completer<int?>();
      final subscription = channel.stdout.listen((chunk) {
        if (counted.isCompleted) return;
        for (final frame in parser.add(chunk)) {
          final message = decodeMessage(frame);
          if (message is SessionsMessage) {
            counted.complete(message.summaries.length);
            return;
          }
          if (message is ErrorMessage) {
            counted.complete(null);
            return;
          }
        }
      }, onError: (Object _) {});
      channel.add(
        const HelloMessage(
          requestId: 1,
          clientId: 'karmashala-deployer',
        ).toFrame().encode(),
      );
      channel.add(const ListMessage(2).toFrame().encode());
      try {
        return await counted.future.timeout(helloTimeout);
      } finally {
        await subscription.cancel();
      }
    } on Object catch (e) {
      _logger.debug('${target.address} would not list its sessions: $e');
      return null;
    } finally {
      await channel?.close();
    }
  }

  /// The executable the running `serve` was started from, or null when the
  /// machine would not say. The filename carries the app version, so this is
  /// what tells one build from another — `kHostVersion` does not.
  Future<String?> _runningServePath(String home) async {
    final result = await target.run(
      'd="\${XDG_RUNTIME_DIR:+\$XDG_RUNTIME_DIR/karmashala}"; '
      '[ -n "\$d" ] || d=${_quote('$home/$remoteHomeSubdirectory')}; '
      'p=\$(cat "\$d/host.lock" 2>/dev/null); '
      'case "\$p" in ""|*[!0-9]*) exit 0;; esac; '
      'ps -o args= -p "\$p" 2>/dev/null | head -1',
    );
    final line = result.stdout.trim();
    if (line.isEmpty) return null;
    // `<path> serve` — the path is everything before the subcommand.
    final serve = line.lastIndexOf(' serve');
    return serve <= 0 ? null : line.substring(0, serve);
  }

  /// Stops the running `serve` by the pid in its own lock file. The directory
  /// is resolved the way `HostPaths` resolves it, which is the one place this
  /// knowledge is duplicated — a lock read from the wrong directory would kill
  /// nothing and report success.
  Future<bool> _stopServe(String home) async =>
      (await _stopServeSaid(home)).contains('karmashala-stopped');

  /// `karmashala-stopped`, `karmashala-no-pid` or `karmashala-still-running`.
  Future<String> _stopServeSaid(String home) async {
    final result = await target.run(
      'd="\${XDG_RUNTIME_DIR:+\$XDG_RUNTIME_DIR/karmashala}"; '
      '[ -n "\$d" ] || d=${_quote('$home/$remoteHomeSubdirectory')}; '
      'p=\$(cat "\$d/host.lock" 2>/dev/null); '
      'case "\$p" in ""|*[!0-9]*) echo karmashala-no-pid; exit 0;; esac; '
      'kill "\$p" 2>/dev/null || true; '
      'for i in 1 2 3 4 5 6 7 8 9 10; do '
      'kill -0 "\$p" 2>/dev/null || { echo karmashala-stopped; exit 0; }; '
      'sleep 0.2; done; echo karmashala-still-running',
    );
    return result.stdout;
  }

  /// The server's own default folder, `~/.karmashala` — never the runtime
  /// dir (tmpfs): its store holds this box's phone pairings. No app writes
  /// rows there, so its lifecycle recording has nothing to write — the feed
  /// is what counts. Phones are served on every interface, as a box paired
  /// from the desktop always was: the flags hold that whatever its
  /// `server.json` says, since no desktop edits a box's file.
  Future<RemoteRun> _startServe(String home, String remotePath) {
    final directory = '$home/$remoteHomeSubdirectory';
    final serve =
        '${_quote(remotePath)} serve --companion ${_quote('--bind=0.0.0.0')}';
    return target.run(
      'mkdir -p ${_quote(directory)} && '
      '${detachedStart(serve, _quote('$directory/host.log'))}; '
      'echo started',
    );
  }

  /// For the shell commands this class builds. The remote home is the machine's
  /// word, not ours, so it is quoted rather than trusted to be one word.
  static String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}

/// Where one artifact goes on the far end. Every path is derived here, so the
/// `.d` convention is stated once: `deploy()` reports [executable] and
/// `_install` writes [upload], and the two cannot drift into disagreeing about
/// what a bundle looks like once it is unpacked.
class _RemoteLayout {
  const _RemoteLayout({
    required this.upload,
    required this.executable,
    required this.unpackInto,
  });

  /// A bundle is unpacked into a directory of its own and run from inside it,
  /// so the executable keeps `../lib` — the SQLite it was built with — beside
  /// it. A bare file from before the store is uploaded straight to where it runs.
  factory _RemoteLayout.of(
    String directory,
    HostBinary binary,
    HostPlatform platform,
  ) {
    final stem = 'karmashala_host-${binary.version}-${platform.targetKey}';
    if (!binary.isBundleArchive) {
      return _RemoteLayout(
        upload: '$directory/$stem',
        executable: '$directory/$stem',
        unpackInto: null,
      );
    }
    final into = '$directory/$stem.d';
    return _RemoteLayout(
      // The archive stays beside the directory: its size is what the next
      // deploy compares against to decide it has nothing to do.
      upload: '$directory/$stem.tar.gz',
      executable: '$into/bin/karmashala_host',
      unpackInto: into,
    );
  }

  final String upload;
  final String executable;

  /// Null for an artifact that is already what it runs as.
  final String? unpackInto;
}

class HostInstallException implements Exception {
  const HostInstallException(this.message, {this.privileged});
  final String message;

  /// What root has to do on the machine first, when that is the remedy.
  final PrivilegedCommand? privileged;
  @override
  String toString() => message;
}

/// What the host said when asked. Not a WelcomeMessage, because a refusal is
/// also an answer and carries only some of the same fields.
class HostGreeting {
  const HostGreeting({
    required this.hostVersion,
    required this.protocolVersion,
    required this.ptyLibrary,
  });

  final String hostVersion;

  /// -1 when the host disagreed about the protocol but did not say which one
  /// it speaks in words we could read.
  final int protocolVersion;
  final String ptyLibrary;
}
