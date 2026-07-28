import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../agents/application/agent_providers.dart';
import '../agents/domain/agent_adapter.dart';
import '../agents/domain/agent_installation.dart';
import '../agents/domain/agent_kind.dart';
import '../environments/application/environment_providers.dart';
import '../environments/domain/environment_kind.dart';
import '../environments/domain/environment_path.dart';
import '../sessions/application/session_engine_provider.dart';
import '../sessions/domain/session_event_types.dart';
import '../settings/application/settings_controller.dart';
import 'launcher_mcp.dart';

enum LauncherChatStatus { idle, connecting, ready, error }

enum LauncherChatRole { user, agent, tool, error }

class LauncherChatMessage {
  const LauncherChatMessage(this.role, this.text);
  final LauncherChatRole role;
  final String text;
}

class LauncherChatState {
  const LauncherChatState({
    this.messages = const [],
    this.status = LauncherChatStatus.idle,
    this.busy = false,
    this.error,
    this.mcpEnabled = false,
  });

  final List<LauncherChatMessage> messages;
  final LauncherChatStatus status;

  /// True while a message is in flight / the agent is responding.
  final bool busy;
  final String? error;

  /// Whether the agent was launched with Chitragupta's MCP tools.
  final bool mcpEnabled;

  LauncherChatState copyWith({
    List<LauncherChatMessage>? messages,
    LauncherChatStatus? status,
    bool? busy,
    String? error,
    bool? mcpEnabled,
  }) => LauncherChatState(
    messages: messages ?? this.messages,
    status: status ?? this.status,
    busy: busy ?? this.busy,
    error: error,
    mcpEnabled: mcpEnabled ?? this.mcpEnabled,
  );
}

/// Drives a single ad-hoc chat with the default agent (Claude Code), launched
/// with Chitragupta's MCP tools so it can query and act on the app's projects
/// and sessions. Shared by the mini launcher and the full shell — the same
/// conversation persists across both.
class LauncherChatController extends Notifier<LauncherChatState> {
  final _logger = AppLogger.named('launcher-chat');
  final _mcp = const LauncherMcp();

  AgentSession? _session;
  StreamSubscription<AgentEvent>? _subscription;

  @override
  LauncherChatState build() {
    ref.onDispose(() {
      _subscription?.cancel();
      _session?.stop();
    });
    return const LauncherChatState();
  }

  Future<void> send(String text) async {
    final message = text.trim();
    if (message.isEmpty) return;
    try {
      await _ensureStarted();
    } catch (e) {
      _append(LauncherChatRole.error, 'Could not start the agent: $e');
      state = state.copyWith(status: LauncherChatStatus.error, busy: false);
      return;
    }
    _append(LauncherChatRole.user, message);
    state = state.copyWith(busy: true);
    try {
      await _session!.send(message);
    } catch (e) {
      _append(LauncherChatRole.error, 'Send failed: $e');
      state = state.copyWith(busy: false);
    }
  }

  /// Ends the conversation and clears it.
  Future<void> reset() async {
    await _subscription?.cancel();
    await _session?.stop();
    _subscription = null;
    _session = null;
    state = const LauncherChatState();
  }

  Future<void> _ensureStarted() async {
    if (_session != null) return;
    state = state.copyWith(status: LauncherChatStatus.connecting);

    final installation = _resolveClaudeInstallation();
    if (installation == null) {
      throw StateError('No Claude Code installation found. Run Discover first.');
    }
    final mcpConfigPath = await _mcp.ensureConfig();
    final permission = ref
        .read(settingsControllerProvider)
        .permissionsFor(AgentKind.claudeCode)
        .existingSessions;

    final adapter = ref.read(agentAdapterResolverProvider)(
      AgentKind.claudeCode,
    );
    final session = adapter.start(
      AgentLaunch(
        workingDirectory: EnvironmentPath(
          environmentId: installation.environmentId,
          path: _workingDirFor(installation),
        ),
        installation: installation,
        permissionMode: permission,
        mcpConfigPath: mcpConfigPath,
        allowedTools: mcpConfigPath == null ? const [] : LauncherMcp.allowedTools,
      ),
    );
    _session = session;
    _subscription = session.events.listen(_onEvent, onError: (Object e) {
      _append(LauncherChatRole.error, '$e');
    });
    state = state.copyWith(
      status: LauncherChatStatus.ready,
      mcpEnabled: mcpConfigPath != null,
    );
    if (mcpConfigPath == null) {
      _logger.info('Launcher chat started without MCP (bridge exe not found).');
    }
  }

  void _onEvent(AgentEvent event) {
    switch (event.type) {
      case SessionEventTypes.agentMessage:
        final text = (event.data['text'] ?? '').toString();
        if (text.trim().isNotEmpty) _append(LauncherChatRole.agent, text);
        state = state.copyWith(busy: false);
      case 'tool.call':
        final name = (event.data['name'] ?? 'tool').toString();
        _append(LauncherChatRole.tool, name);
      case SessionEventTypes.error:
        final msg = (event.data['message'] ?? 'error').toString();
        _append(LauncherChatRole.error, msg);
        state = state.copyWith(busy: false);
      case SessionEventTypes.agentStatus:
        // 'result' status marks the end of a turn.
        if (event.data['state'] == 'result') {
          state = state.copyWith(busy: false);
        }
    }
  }

  void _append(LauncherChatRole role, String text) {
    state = state.copyWith(
      messages: [...state.messages, LauncherChatMessage(role, text)],
    );
  }

  /// Prefer a Claude install in the Windows host (so the MCP bridge can reach
  /// the loopback control server); fall back to any Claude install.
  AgentInstallation? _resolveClaudeInstallation() {
    final installs = ref
        .read(agentInstallationDaoProvider)
        .getAll()
        .where((i) => i.agentKind == AgentKind.claudeCode)
        .toList();
    if (installs.isEmpty) return null;
    final environmentDao = ref.read(executionEnvironmentDaoProvider);
    for (final install in installs) {
      final env = environmentDao.getById(install.environmentId);
      if (env?.kind == EnvironmentKind.windowsNative) return install;
    }
    return installs.first;
  }

  String _workingDirFor(AgentInstallation installation) {
    final env = ref
        .read(executionEnvironmentDaoProvider)
        .getById(installation.environmentId);
    if (env?.kind == EnvironmentKind.windowsNative) {
      return Platform.environment['USERPROFILE'] ?? '.';
    }
    return Platform.environment['HOME'] ?? '.';
  }
}

final launcherChatControllerProvider =
    NotifierProvider<LauncherChatController, LauncherChatState>(
      LauncherChatController.new,
    );

/// Whether the launcher chat panel is currently shown. Shared so the mini
/// launcher and the full shell toggle the same panel.
class LauncherChatVisible extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void set(bool value) => state = value;
}

final launcherChatVisibleProvider =
    NotifierProvider<LauncherChatVisible, bool>(LauncherChatVisible.new);
