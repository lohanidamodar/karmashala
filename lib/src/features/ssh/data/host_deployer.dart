import 'dart:async';
import 'dart:convert';

import 'package:karmashala_host/protocol.dart';

import 'package:karmashala_core/logging.dart';
import '../domain/host_deployment.dart';
import 'host_binaries.dart';
import 'host_deploy_target.dart';

/// Puts the session host on a machine and confirms it answers.
///
/// The order is: measure the machine, pick a binary, resolve the remote home,
/// skip the upload when what is already there matches, install, ask it `hello`,
/// and start it only if that fails. Every outcome is a [HostDeployment] carrying
/// the time it was taken — a host that answered five minutes ago is not a host
/// that is answering.
///
/// The home is *resolved*, never spelled: a deploy is half shell commands and
/// half SFTP, and only one of those two expands `$HOME`.
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

  /// What is hung off the remote home: `~/.karmashala`, matching where the host
  /// itself falls back to for its socket, so everything it owns on a machine is
  /// under one directory a person can delete.
  ///
  /// A *fragment*, never a path. The path is built from the home this deploy
  /// resolved, because half of what a deploy does never sees a shell: `mkdir`
  /// and `wc` expand `$HOME`, SFTP does not, and a literal `$HOME/...` handed
  /// to `sftp.open` is a directory that does not exist. Every deploy went that
  /// way until 2026-09-10.
  static const String remoteHomeSubdirectory = '.karmashala';

  Future<HostDeployment> deploy() async {
    final platform = await measurePlatform();
    if (platform == null) {
      return HostDeployment.unknown('${target.address} did not answer `uname -sm`.', _now());
    }
    if (platform.libc == HostLibc.musl) {
      return HostDeployment(
        status: HostDeploymentStatus.unsupportedPlatform,
        observedAt: _now(),
        platform: platform,
        reason:
            '${target.address} runs musl libc. The host binaries are glibc-linked ELF '
            'cross-compiled from the Windows Dart SDK, so there is nothing to send.',
      );
    }
    if (!platform.isLinux) {
      return HostDeployment(
        status: HostDeploymentStatus.unsupportedPlatform,
        observedAt: _now(),
        platform: platform,
        reason:
            '${target.address} runs ${platform.operatingSystem}; the host is built for Linux '
            'only. The Windows Dart SDK cannot cross-compile for macOS at all.',
      );
    }

    final binary = await binaries.binaryFor(platform);
    if (binary == null) {
      final have = await binaries.availableTargets();
      return HostDeployment(
        status: HostDeploymentStatus.noBinary,
        observedAt: _now(),
        platform: platform,
        reason:
            'No host binary for ${platform.targetKey} in this build'
            '${have.isEmpty ? '' : ' (it has ${have.join(', ')})'}.',
      );
    }
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
    final remotePath = '$remoteDirectory/karmashala_host-${binary.version}-${platform.targetKey}';
    try {
      await _install(remoteDirectory, remotePath, binary);
    } on HostInstallException catch (e) {
      return HostDeployment(
        status: HostDeploymentStatus.cannotInstall,
        observedAt: _now(),
        platform: platform,
        remotePath: remotePath,
        reason: e.message,
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
          '${restarted ? ' It was not running and has been restarted, so any sessions it held before are gone.' : ''}',
    );
  }

  /// `uname -sm` plus a libc reading, in one command so it costs one channel.
  Future<HostPlatform?> measurePlatform() async {
    final result = await target.run(
      // `ldd --version` writes to stderr on some builds and stdout on others,
      // and Alpine's exits non-zero; the redirect and the `|| true` are what
      // make the reading survive both.
      'uname -s; uname -m; (ldd --version 2>&1 || true) | head -1',
    );
    final lines = const LineSplitter().convert(result.stdout).where((l) => l.isNotEmpty).toList();
    if (lines.length < 2) return null;
    final libcLine = (lines.length > 2 ? lines[2] : '').toLowerCase();
    return HostPlatform(
      operatingSystem: lines[0].toLowerCase(),
      architecture: HostPlatform.normaliseArchitecture(lines[1]),
      libc: libcLine.contains('musl')
          ? HostLibc.musl
          : libcLine.contains('glibc') || libcLine.contains('gnu libc')
          ? HostLibc.glibc
          // Not "glibc by default": a machine that did not say is a machine we
          // do not know about, and the deployer treats unknown as worth trying
          // while reporting it as unknown.
          : HostLibc.unknown,
      observedAt: _now(),
    );
  }

  /// The remote home as an absolute path, asked of the machine's own shell.
  ///
  /// Null when it did not answer with one — which is *unknown*, never a guess
  /// at `/home/<user>`: a deploy that spells the path itself is how a literal
  /// `$HOME` reached SFTP in the first place. The last non-empty line is taken
  /// so a shell rc file that prints something cannot be read as a home.
  Future<String?> resolveHome() async {
    final RemoteRun result;
    try {
      result = await target.run('echo "\$HOME"');
    } on Object catch (e) {
      _logger.debug('${target.address} could not be asked for \$HOME: $e');
      return null;
    }
    final lines = const LineSplitter()
        .convert(result.stdout)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);
    if (lines.isEmpty) return null;
    final home = lines.last;
    // An answer that is not an absolute path is not an answer: `$HOME` unset
    // echoes an empty line, and a shell that printed a complaint is not a home.
    if (!home.startsWith('/')) return null;
    return home.length > 1 && home.endsWith('/') ? home.substring(0, home.length - 1) : home;
  }

  /// Uploads unless the remote file is already exactly this size. Size, not a
  /// checksum: the version is in the filename, so a same-named file of the same
  /// length is the same build, and hashing megabytes over SSH on every pane
  /// open would cost more than it saves.
  Future<void> _install(String remoteDirectory, String remotePath, HostBinary binary) async {
    final existing = await target.run(
      'mkdir -p ${_quote(remoteDirectory)} && wc -c < ${_quote(remotePath)} 2>/dev/null || echo missing',
    );
    final reported = existing.stdout.trim();
    if (reported == '${binary.bytes.length}') {
      _logger.debug('$remotePath is already ${binary.bytes.length} bytes; skipping the upload.');
      // Still make sure it can run: a file restored from a backup, or copied
      // by something that dropped the mode, is the size it should be and is
      // not executable.
      await target.run('chmod +x ${_quote(remotePath)}');
      return;
    }
    if (!existing.ok && reported != 'missing') {
      throw HostInstallException(
        'Could not reach $remoteDirectory on ${target.address}: ${existing.output}',
      );
    }
    try {
      await target.upload(remotePath, binary.bytes);
    } on Object catch (e) {
      throw HostInstallException(
        'Could not write $remotePath on ${target.address} ($e). A read-only home '
        'directory or a full disk would look like this.',
      );
    }
    final chmod = await target.run(
      'chmod +x ${_quote(remotePath)} && test -x ${_quote(remotePath)}',
    );
    if (!chmod.ok) {
      throw HostInstallException(
        '$remotePath was uploaded to ${target.address} but cannot be executed '
        '(${chmod.output.isEmpty ? 'exit ${chmod.exitCode}' : chmod.output}). '
        'A noexec home directory looks like this.',
      );
    }
  }

  /// Runs `attach` and completes the handshake, which is the only proof that
  /// matters: the file being present is not the host answering. A refusal is
  /// an answer too — a protocol mismatch names both versions, and that is
  /// exactly what the caller has to report.
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
        for (final frame in parser.add(chunk)) {
          final message = decodeMessage(frame);
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
        const HelloMessage(requestId: 1, clientId: 'karmashala-deployer').toFrame().encode(),
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

  /// The host's own words carry its version. Quoted back, never guessed: if the
  /// wording ever changes this reports an unknown version rather than a wrong
  /// one, and the caller still knows the two ends disagree.
  static HostGreeting? _greetingFromRefusal(ErrorMessage refusal) {
    if (refusal.code != ProtocolErrorCode.protocolMismatch) return null;
    final match = RegExp(r'host speaks protocol (\d+)').firstMatch(refusal.message);
    return HostGreeting(
      hostVersion: 'unknown',
      protocolVersion: match == null ? -1 : int.parse(match.group(1)!),
      ptyLibrary: 'unknown',
    );
  }

  /// `setsid nohup … &`, so the daemon is out of this channel's process group
  /// before the channel closes. Output goes to a log next to the socket rather
  /// than into the channel, which would keep it open.
  Future<RemoteRun> _startServe(String home, String remotePath) {
    final directory = '$home/$remoteHomeSubdirectory';
    return target.run(
      'mkdir -p ${_quote(directory)} && '
      'setsid nohup ${_quote(remotePath)} serve >> ${_quote('$directory/host.log')} '
      '2>&1 < /dev/null & '
      'echo started',
    );
  }

  /// For the shell commands this class builds. The remote home is the machine's
  /// word, not ours, so it is quoted rather than trusted to be one word.
  static String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}

class HostInstallException implements Exception {
  const HostInstallException(this.message);
  final String message;
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
