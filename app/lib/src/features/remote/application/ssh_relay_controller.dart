/// Driving the relay on a box — set it up, look at it, stop it, take it away
/// — through the server, which does it over its own connection (slice 5d);
/// and keeping what remote access serves through in line with what was found.
library;

import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SshBoxAnswer, SshRelayAction;
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/failure_words.dart';
import '../../ssh/data/ssh_client.dart';
import 'remote_access_controller.dart';
import 'ssh_relays.dart';

/// What is known about one box's relay since this launch. A reading, with its
/// time — nothing here is re-checked on its own (§19).
class SshRelayView {
  const SshRelayView({
    this.reading,
    this.busy = false,
    this.failure,
    this.deployment,
  });

  final SshRelayReading? reading;
  final bool busy;

  /// Why the box could not even be asked, worded for a person: no connection,
  /// a host key that changed.
  final String? failure;

  /// The deploy that put nothing on the box — a sentence, a remedy and an
  /// Install button, rather than a [failure] string.
  final HostDeployment? deployment;
}

class SshRelayController extends Notifier<Map<String, SshRelayView>> {
  @override
  Map<String, SshRelayView> build() => const {};

  /// Sets the relay up on [host] — or updates or restarts it; `start` is all
  /// three — and serves through it once it has answered from here.
  /// [ruleAddedByHand] is "Check again" after the firewall command was run in
  /// a terminal on the box.
  Future<SshRelayReading?> use(
    SshHost host, {
    required int port,
    bool ruleAddedByHand = false,
  }) => _run(
    host,
    port,
    SshRelayAction.start,
    ruleAddedByHand: ruleAddedByHand,
  );

  /// Looks, and changes nothing on the box.
  Future<SshRelayReading?> check(SshHost host, {required int port}) =>
      _run(host, port, SshRelayAction.check);

  /// Stops it there and stops serving through it. The box stays in the list.
  Future<SshRelayReading?> stop(SshHost host, {required int port}) =>
      _run(host, port, SshRelayAction.stop);

  /// Stops it, deletes its token, pid and log on the box, and forgets it here.
  /// The host bundle stays: the session host runs from it.
  Future<SshRelayReading?> remove(SshHost host, {required int port}) async {
    final reading = await _run(host, port, SshRelayAction.remove);
    // Forgotten only once the box said it is gone: forgetting a relay that is
    // still running would leave a listener on somebody's server with no row
    // here to stop it from.
    if (reading != null && reading.status == SshRelayStatus.stopped) {
      forget(host.id);
    }
    return reading;
  }

  /// Drops the row without touching the box — for a host that was deleted
  /// from Settings, where there is nothing left to connect with.
  void forget(String hostId) {
    ref.read(sshRelaysProvider.notifier).remove(hostId);
    state = {...state}..remove(hostId);
    unawaited(ref.read(remoteAccessControllerProvider).sync());
  }

  Future<SshRelayReading?> _run(
    SshHost host,
    int port,
    SshRelayAction action, {
    bool ruleAddedByHand = false,
  }) async {
    _set(host.id, SshRelayView(reading: state[host.id]?.reading, busy: true));
    final SshBoxAnswer<SshRelayReading> answer;
    try {
      answer = await ref
          .read(sshClientProvider)
          .relay(host.id, action, port: port, ruleAddedByHand: ruleAddedByHand);
    } on Object catch (error) {
      _set(
        host.id,
        SshRelayView(
          reading: state[host.id]?.reading,
          failure: describeFailure(error),
        ),
      );
      return null;
    }
    final reading = answer.value;
    if (reading == null) {
      // The host bundle could not be put on the box: its sentence, remedy
      // and Install button, rather than a failure string.
      _set(
        host.id,
        SshRelayView(
          reading: state[host.id]?.reading,
          deployment: answer.deployment,
        ),
      );
      return null;
    }
    _record(host, port, reading);
    _set(host.id, SshRelayView(reading: reading));
    return reading;
  }

  /// Brings the stored entry in line with a reading. Served through only while
  /// it answers from this computer: the desktop dials the relay outbound, so a
  /// relay it cannot reach is one it cannot serve through either.
  void _record(SshHost host, int port, SshRelayReading reading) {
    final relays = ref.read(sshRelaysProvider.notifier);
    final existing = relays.entryFor(host.id);
    final url = reading.url ?? existing?.url;
    // Nothing to remember: it never started, so there is no token and no URL.
    if (url == null) return;
    final entry = SshRelayEntry(
      hostId: host.id,
      hostName: host.name,
      port: port,
      url: url,
      enabled: switch (reading.status) {
        SshRelayStatus.running => true,
        // Still up, from an older bundle — an app update must not drop the
        // phones on it — and a reading nobody could take changes nothing.
        SshRelayStatus.outdated ||
        SshRelayStatus.unknown => existing?.enabled ?? false,
        SshRelayStatus.stopped ||
        SshRelayStatus.unreachable ||
        SshRelayStatus.cannotStart => false,
      },
    );
    if (entry == existing) return;
    relays.put(entry);
    unawaited(ref.read(remoteAccessControllerProvider).sync());
  }

  void _set(String hostId, SshRelayView view) =>
      state = {...state, hostId: view};
}

final sshRelayControllerProvider =
    NotifierProvider<SshRelayController, Map<String, SshRelayView>>(
      SshRelayController.new,
    );
