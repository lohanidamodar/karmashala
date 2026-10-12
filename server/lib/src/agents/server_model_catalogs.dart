import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../data/data_service.dart';

/// **The models each agent installation reports, read by the server** — at a
/// session's launch and when a client asks — through the adapter's
/// [AgentModelLister], in the installation's own environment: this machine, a
/// WSL distribution, or an SSH box over the server's connection. Kept per
/// installation for [ttl] and in the server's metadata, so a restart answers
/// from the last good list; a failed read keeps that list and says why.
class ServerModelCatalogs {
  ServerModelCatalogs({
    required DataService data,
    required CommandRunner Function(ExecutionEnvironment environment) runnerFor,
    this.registry = AgentRegistry.builtIn,
    Clock clock = const SystemClock(),
    Map<String, String> hostEnvironment = const {},
    bool? hostIsWindows,
    this.ttl = kAgentModelsTtl,
  }) : _data = data,
       _runnerFor = runnerFor,
       _clock = clock,
       _hostEnvironment = hostEnvironment,
       _hostIsWindows = hostIsWindows ?? Platform.isWindows;

  final DataService _data;
  final CommandRunner Function(ExecutionEnvironment environment) _runnerFor;
  final AgentRegistry registry;
  final Clock _clock;
  final Map<String, String> _hostEnvironment;
  final bool _hostIsWindows;
  final Duration ttl;

  final _held = <String, AgentModelCatalog>{};
  final _reading = <String, Future<AgentModelCatalog>>{};

  static String _key(String installationId) => 'agentModels.$installationId';

  /// [installationId]'s catalogue: the held one while younger than [ttl],
  /// else — or with [refresh] — read from the agent first. One read at a time
  /// per installation.
  Future<AgentModelCatalog> read(
    String installationId, {
    bool refresh = false,
  }) async {
    final installation = _data.installations
        .where((i) => i.id == installationId)
        .firstOrNull;
    if (installation == null) {
      throw DataRefused.notFound('no agent installation $installationId');
    }
    final lister = registry.adapterFor(installation.agentId)?.modelLister;
    if (lister == null) {
      return AgentModelCatalog(installationId: installationId);
    }
    final held = _heldOf(installationId);
    if (!refresh && held != null && !held.isStale(_clock.nowUtc(), ttl)) {
      return held;
    }
    return _reading[installationId] ??= _read(installation, lister, held)
        .whenComplete(() {
          // A block, not an arrow: `remove` answers this very future, and
          // `whenComplete` would wait on it.
          _reading.remove(installationId);
        });
  }

  /// Ages [installationId]'s list so the next read asks the agent — its
  /// account changed — while keeping it as the fallback.
  void markStale(String installationId) {
    final held = _heldOf(installationId);
    if (held == null) return;
    _store(
      AgentModelCatalog(
        installationId: installationId,
        models: held.models,
        source: held.source,
        failure: held.failure,
        failedAt: held.failedAt,
      ),
    );
  }

  AgentModelCatalog? _heldOf(String installationId) {
    final held = _held[installationId];
    if (held != null) return held;
    final saved = _data.serverValue(_key(installationId));
    if (saved == null) return null;
    try {
      return _held[installationId] = AgentModelCatalog.fromJson(
        (jsonDecode(saved) as Map).cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }

  void _store(AgentModelCatalog catalog) {
    _held[catalog.installationId] = catalog;
    _data.setServerValue(
      _key(catalog.installationId),
      jsonEncode(catalog.toJson()),
    );
  }

  Future<AgentModelCatalog> _read(
    AgentInstallation installation,
    AgentModelLister lister,
    AgentModelCatalog? held,
  ) async {
    final now = _clock.nowUtc();
    String? failure;
    List<AgentModel>? found;
    try {
      final context = _contextFor(installation);
      if (context == null) {
        failure = 'its environment is not one this server reaches';
      } else {
        found = await lister.list(context);
        if (found == null) failure = '${lister.source} named no models';
      }
    } on Object catch (error) {
      failure = '${lister.source} failed: $error';
    }
    final catalog = found != null
        ? AgentModelCatalog(
            installationId: installation.id,
            models: List.unmodifiable(found),
            readAt: now,
            source: lister.source,
          )
        : AgentModelCatalog(
            installationId: installation.id,
            models: held?.models ?? const [],
            readAt: held?.readAt,
            source: lister.source,
            failure: failure,
            failedAt: now,
          );
    _store(catalog);
    return catalog;
  }

  ModelListContext? _contextFor(AgentInstallation installation) {
    final environment = _data.environments
        .where((e) => e.id == installation.environmentId)
        .firstOrNull;
    if (environment == null) return null;
    final runner = _runnerFor(environment);
    final onHost = installation.environmentId == localHostEnvironmentId;
    return ModelListContext(
      hostEnvironment: _hostEnvironment,
      hostIsWindows: _hostIsWindows,
      runLocalCli:
          (
            arguments, {
            stdinText,
            timeout = const Duration(seconds: 30),
          }) async {
            final result = await runner.run(
              CommandRequest(
                executable: installation.executable.path,
                arguments: arguments,
                stdinText: stdinText,
                timeout: timeout,
              ),
            );
            return result.ok ? result.stdout : null;
          },
      runInEnvironment: onHost
          ? null
          : (executable, arguments) async {
              // The listers' own words, for the environment's shell to
              // expand, as WSL's does; SSH quotes each argument, so it is
              // handed to a shell there as one script.
              final result = await runner.run(
                environment.kind == EnvironmentKind.ssh
                    ? CommandRequest(
                        executable: 'sh',
                        arguments: [
                          '-c',
                          [executable, ...arguments].join(' '),
                        ],
                      )
                    : CommandRequest(
                        executable: executable,
                        arguments: arguments,
                      ),
              );
              return result.ok ? result.stdout : null;
            },
    );
  }
}
