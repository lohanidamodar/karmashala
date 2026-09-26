import 'dart:async';

import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;

import '../domain/session_registry.dart';
import 'daemon_agents.dart';

/// Watches the screen of an agent this host started unattended for the first
/// minutes of its life, and says when it is sitting at its first-run question
/// (directory trust) — which nobody is there to answer, so the run would
/// otherwise wait for its ceiling, or forever.
///
/// It reads and reports; it never types. Trusting a folder is the person's
/// decision. What the agent declares it draws for that question is the
/// adapter's (`AgentLaunchSpec.firstRunPrompt`), asked through [agents].
class FirstRunPromptWatch {
  FirstRunPromptWatch({
    required this.registry,
    required this.onBlocked,
    this.agents = const DaemonAgents(),
    this.interval = const Duration(seconds: 2),
    this.within = const Duration(minutes: 3),
  });

  final SessionRegistry registry;
  final DaemonAgents agents;

  /// The session [sessionId] is blocked, for [reason]. True once it was acted
  /// on; false keeps watching (the run may not name its session yet).
  final bool Function(String sessionId, String reason) onBlocked;

  /// How often the screen is read.
  final Duration interval;

  /// How long after the launch the question is looked for: it is drawn in the
  /// first seconds, and a screen that matches later is the conversation, not
  /// the question.
  final Duration within;

  final Map<String, Timer> _timers = {};
  var _closed = false;

  /// Starts watching [sessionId], an [agentId] launched in [directory].
  void follow({
    required String sessionId,
    required String agentId,
    required String directory,
  }) {
    if (_closed) return;
    // An agent that declares no question is never looked at.
    final rules = agents.descriptorOf(agentId)?.launch.firstRunPrompt;
    if (rules == null || rules.isEmpty) return;
    _timers.remove(sessionId)?.cancel();
    final startedAt = DateTime.now();
    _timers[sessionId] = Timer.periodic(interval, (timer) {
      if (_closed || DateTime.now().difference(startedAt) > within) {
        _stop(sessionId, timer);
        return;
      }
      final session = registry.find(hostSessionIdOf(sessionId));
      if (session == null || session.lifecycle.hasEnded) {
        _stop(sessionId, timer);
        return;
      }
      final reason = agents.firstRunPromptOn(
        agentId,
        session.tailText(rules.scanLines),
        directory: directory,
      );
      if (reason == null) return;
      if (onBlocked(sessionId, reason)) _stop(sessionId, timer);
    });
  }

  void _stop(String sessionId, Timer timer) {
    timer.cancel();
    if (identical(_timers[sessionId], timer)) _timers.remove(sessionId);
  }

  /// The sessions still being watched.
  Iterable<String> get watching => _timers.keys;

  void close() {
    _closed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
