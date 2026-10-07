import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_session/session.dart';

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
        checkout ??
        (throw StateError('The checkout is no longer in the workspace.'));
    final place = facts.rows.environment(directory.environmentId);
    if (place == null || !facts.runsChecksIn(directory)) {
      throw StateError(
        'This server cannot run commands where this checkout is.',
      );
    }
    final runner =
        facts.remoteRunnerFor(directory) ?? exactRunner(place, _local);
    final windows = place.kind == EnvironmentKind.windowsNative;
    final CommandResult result;
    try {
      result = await runner.run(
        CommandRequest(
          executable: windows ? 'powershell.exe' : 'sh',
          arguments: windows
              ? ['-NoProfile', '-NonInteractive', '-Command', command]
              : ['-c', command],
          workingDirectory: directory,
          environment: environment,
          timeout: timeout,
        ),
      );
    } on CommandException catch (error) {
      if (error.message.contains('did not finish within')) {
        return const StepCommandResult(
          exitCode: null,
          output: '',
          timedOut: true,
        );
      }
      throw StateError('It did not start: ${error.message}');
    }
    return StepCommandResult(
      exitCode: result.exitCode,
      output: '${result.stdout}${result.stderr}',
    );
  }
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
