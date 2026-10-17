import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_session/session.dart';
import 'package:path/path.dart' as p;

import 'daemon_checkout_facts.dart';

/// A command step, run where the agent worked: its session's worktree, else
/// the checkout. PowerShell on Windows, `sh` elsewhere — neither re-reads a
/// variable's value as syntax, so the values cross only as the environment.
class ServerStepCommands implements StepCommandRunner {
  ServerStepCommands({
    required this.facts,
    required this.sessionOf,
    CommandRunnerFactory? local,
  }) : _local = local ?? const CommandRunnerFactory();

  final DaemonCheckoutFacts facts;
  final Session? Function(String sessionId) sessionOf;
  final CommandRunnerFactory _local;

  @override
  Future<StepCommandResult> run(
    Automation automation,
    AutomationRun run, {
    required String command,
    required Map<String, String> environment,
    required Duration timeout,
  }) async {
    final checkout = facts.repository(automation.repositoryId)?.path;
    final sessionId = run.sessionId;
    final directory =
        (sessionId == null ? null : sessionOf(sessionId)?.worktree) ??
        automation.folder ??
        checkout ??
        (throw StateError('The checkout is no longer in the workspace.'));
    final place = facts.rows.environment(directory.environmentId);
    if (place == null || !facts.runsChecksIn(directory)) {
      throw StateError(
        'This server cannot run commands on '
        '${place?.name ?? directory.environmentId}.',
      );
    }
    final runner =
        facts.remoteRunnerFor(directory) ?? exactRunner(place, _local);
    final request = commandRequest(
      automation,
      place,
      directory,
      command: command,
      environment: environment,
      timeout: timeout,
      batchFile: () => File(
        p.join(Directory.systemTemp.path, 'karmashala-run-${run.id}.cmd'),
      ),
    );
    final CommandResult result;
    try {
      result = await runner.run(request.request);
    } on CommandException catch (error) {
      if (error.message.contains('did not finish within')) {
        return const StepCommandResult(
          exitCode: null,
          output: '',
          timedOut: true,
        );
      }
      throw StateError('It did not start: ${error.message}');
    } finally {
      await request.cleanUp();
    }
    return StepCommandResult(
      exitCode: result.exitCode,
      output: '${result.stdout}${result.stderr}',
    );
  }
}

/// How [command] is handed to [place]'s shell. Windows runs PowerShell, or
/// cmd from a batch file when a command automation chose it; elsewhere a
/// command automation runs in the user's login shell, from [directory] with
/// `~` read as home, and a step in a checkout runs in `sh`. The command and
/// the folder cross as arguments, never as a line to parse.
({CommandRequest request, Future<void> Function() cleanUp}) commandRequest(
  Automation automation,
  ExecutionEnvironment place,
  EnvironmentPath directory, {
  required String command,
  required Map<String, String> environment,
  required Duration timeout,
  required File Function() batchFile,
  Map<String, String>? hostEnvironment,
}) {
  Future<void> nothing() async {}
  final shell = automation.command?.shell;
  if (place.kind == EnvironmentKind.windowsNative) {
    final folder = EnvironmentPath(
      environmentId: directory.environmentId,
      path: homeExpanded(
        directory.path,
        (hostEnvironment ?? Platform.environment)['USERPROFILE'],
      ),
    );
    if (shell == AutomationShell.cmd) {
      final file = batchFile();
      // Lines run in turn, and !NAME! reads a value without re-parsing it.
      file.writeAsStringSync(
        '@echo off\r\nsetlocal EnableDelayedExpansion\r\n'
        '${command.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')}\r\n',
      );
      return (
        request: CommandRequest(
          executable: 'cmd.exe',
          arguments: ['/d', '/c', 'call', file.path],
          workingDirectory: folder,
          environment: environment,
          timeout: timeout,
        ),
        cleanUp: () async {
          try {
            await file.delete();
          } on FileSystemException {
            // Already gone, or held a moment longer by cmd: temp is temp.
          }
        },
      );
    }
    return (
      request: CommandRequest(
        executable: 'powershell.exe',
        arguments: ['-NoProfile', '-NonInteractive', '-Command', command],
        workingDirectory: folder,
        environment: environment,
        timeout: timeout,
      ),
      cleanUp: nothing,
    );
  }
  if (automation.runsCommand) {
    return (
      request: CommandRequest(
        executable: 'sh',
        arguments: [
          '-c',
          kLoginShellScript,
          'karmashala',
          command,
          directory.path,
        ],
        environment: environment,
        timeout: timeout,
      ),
      cleanUp: nothing,
    );
  }
  return (
    request: CommandRequest(
      executable: 'sh',
      arguments: ['-c', command],
      workingDirectory: directory,
      environment: environment,
      timeout: timeout,
    ),
    cleanUp: nothing,
  );
}

/// Moves to `$2` (`~` is home), then runs `$1` in the user's login shell.
const String kLoginShellScript = r'''
[ -n "${HOME:-}" ] || HOME=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
d=$2
case $d in "~") d=$HOME ;; "~/"*) d=$HOME/${d#"~/"} ;; esac
cd -- "$d" || { echo "No such folder: $d" >&2; exit 1; }
s=${SHELL:-}
[ -n "$s" ] || s=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
[ -x "$s" ] || s=/bin/sh
exec "$s" -lc "$1"
''';

/// [path] with a leading `~` read as [home], on Windows.
String homeExpanded(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  if (path == '~') return home;
  if (path.startsWith('~/') || path.startsWith(r'~\')) {
    return '$home\\${path.substring(2)}';
  }
  return path;
}

/// A runner for [place] that hands each argument over byte for byte. In WSL
/// that is `wsl.exe --exec`: the default re-parses the line in the user's
/// shell, where a query's `&` or a header's quotes break it.
CommandRunner exactRunner(
  ExecutionEnvironment place,
  CommandRunnerFactory runners,
) {
  final distribution = place.wslDistribution;
  if (place.kind == EnvironmentKind.wsl && distribution != null) {
    return WslCommandRunner(
      environmentId: place.id,
      distribution: distribution,
      exec: true,
    );
  }
  return runners.forEnvironment(place);
}

/// Whether [address] is private, loopback, link-local, multicast or
/// unspecified — somewhere on the caller's own network rather than the
/// internet.
bool isPrivateAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return true;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv6) {
    if (bytes.every((b) => b == 0)) return true;
    // An IPv4 address written as IPv6 (::ffff:a.b.c.d) is judged as itself.
    final mapped =
        bytes.sublist(0, 10).every((b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (mapped) {
      return isPrivateAddress(
        InternetAddress.fromRawAddress(bytes.sublist(12)),
      );
    }
    return (bytes[0] & 0xfe) == 0xfc;
  }
  final a = bytes[0], b = bytes[1];
  return a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

/// The most of a webhook's answer that is read.
const int kStepWebhookAnswerCap = 64 * 1024;

/// A webhook step's POST. The host is resolved once and the connection made
/// to the address that was vetted, so a name cannot answer differently
/// between the check and the call.
class ServerStepWebhooks implements StepWebhookPoster {
  ServerStepWebhooks({
    Future<List<InternetAddress>> Function(String host)? lookup,
    HttpClient Function()? client,
  }) : _lookup = lookup ?? InternetAddress.lookup,
       _client = client ?? HttpClient.new;

  final Future<List<InternetAddress>> Function(String host) _lookup;
  final HttpClient Function() _client;

  @override
  Future<StepWebhookResult> post(
    Uri url, {
    required String body,
    required String idempotencyKey,
    required bool allowPrivate,
    required Duration timeout,
  }) async {
    final literal = InternetAddress.tryParse(url.host);
    final List<InternetAddress> addresses;
    try {
      addresses = literal != null
          ? [literal]
          : await _lookup(url.host).timeout(timeout);
    } on Object catch (error) {
      throw StateError('${url.host} could not be found: $error');
    }
    if (addresses.isEmpty) throw StateError('${url.host} could not be found.');
    if (!allowPrivate) {
      for (final address in addresses) {
        if (isPrivateAddress(address)) {
          throw StateError(
            '${url.host} is on your own network (${address.address}), so it '
            'was not called. Tick "Allow addresses on my network" to call it.',
          );
        }
      }
    }
    final pinned = addresses.first;
    final client = _client()
      ..connectionTimeout = timeout
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) => uri.scheme == 'https'
          ? SecureSocket.startConnect(pinned, uri.port)
          : Socket.startConnect(pinned, uri.port);
    try {
      return await _send(client, url, body, idempotencyKey).timeout(timeout);
    } on TimeoutException {
      throw StateError(
        '${url.host} did not answer within ${timeout.inSeconds}s.',
      );
    } on StateError {
      rethrow;
    } on Object catch (error) {
      throw StateError('The call to ${url.host} failed: $error');
    } finally {
      client.close(force: true);
    }
  }

  Future<StepWebhookResult> _send(
    HttpClient client,
    Uri url,
    String body,
    String idempotencyKey,
  ) async {
    final request = await client.postUrl(url);
    request.followRedirects = false;
    request.headers
      ..contentType = ContentType.json
      ..set('Idempotency-Key', idempotencyKey)
      ..set(HttpHeaders.userAgentHeader, 'Karmashala automation');
    request.add(utf8.encode(body));
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length >= kStepWebhookAnswerCap) break;
    }
    return StepWebhookResult(
      status: response.statusCode,
      body: utf8.decode(
        bytes.length > kStepWebhookAnswerCap
            ? bytes.sublist(0, kStepWebhookAnswerCap)
            : bytes,
        allowMalformed: true,
      ),
    );
  }
}
