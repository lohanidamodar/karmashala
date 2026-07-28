import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../agents/domain/agent_kind.dart';
import '../data/settings_repository.dart';
import '../domain/app_theme_mode.dart';
import '../domain/mini_position.dart';
import '../domain/permission_mode.dart';
import '../domain/settings.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

/// Holds the user [Settings], persisting every change.
class SettingsController extends Notifier<Settings> {
  @override
  Settings build() => ref.watch(settingsRepositoryProvider).load();

  void setThemeMode(AppThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    _save();
  }

  void setDefaultTerminalProfile(String profileId) {
    state = state.copyWith(defaultTerminalProfileId: profileId);
    _save();
  }

  void setKeepAwake(bool value) {
    state = state.copyWith(keepAwake: value);
    _save();
  }

  void setCloseToTray(bool value) {
    state = state.copyWith(closeToTray: value);
    _save();
  }

  void setAutoStart(bool value) {
    state = state.copyWith(autoStart: value);
    _save();
  }

  void setExplorerPaneWidth(double value) {
    state = state.copyWith(explorerPaneWidth: value);
    _save();
  }

  void setDetailSidebarWidth(double value) {
    state = state.copyWith(detailSidebarWidth: value);
    _save();
  }

  void setCompactDensity(bool value) {
    state = state.copyWith(compactDensity: value);
    _save();
  }

  void setWindowSize(double width, double height) {
    state = state.copyWith(windowWidth: width, windowHeight: height);
    _save();
  }

  void setMiniSize(double width, double height) {
    state = state.copyWith(miniWidth: width, miniHeight: height);
    _save();
  }

  void setMiniPosition(MiniPosition position) {
    state = state.copyWith(miniPosition: position);
    _save();
  }

  /// Pins/unpins a project; pinned projects sort to the top.
  void togglePinnedProject(String projectId) {
    final pinned = [...state.pinnedProjectIds];
    if (!pinned.remove(projectId)) pinned.add(projectId);
    state = state.copyWith(pinnedProjectIds: pinned);
    _save();
  }

  /// Pins/unpins a session; pinned sessions sort to the top of their project.
  void togglePinnedSession(String sessionId) {
    final pinned = [...state.pinnedSessionIds];
    if (!pinned.remove(sessionId)) pinned.add(sessionId);
    state = state.copyWith(pinnedSessionIds: pinned);
    _save();
  }

  void setDefaultSystemTerminal(String id) {
    state = state.copyWith(defaultSystemTerminalId: id);
    _save();
  }

  void setCustomTerminalPath(String path) {
    state = state.copyWith(
      defaultSystemTerminalId: 'custom',
      customTerminalPath: path,
    );
    _save();
  }

  void setDefaultCodeEditor(String id) {
    state = state.copyWith(defaultCodeEditorId: id);
    _save();
  }

  void setCustomEditorPath(String path) {
    state = state.copyWith(
      defaultCodeEditorId: 'custom',
      customEditorPath: path,
    );
    _save();
  }

  void setDefaultAgent(AgentKind? kind) {
    state = state.copyWith(defaultAgent: kind, clearDefaultAgent: kind == null);
    _save();
  }

  /// Sets the default to a specific installation (or clears it). Keeps
  /// [Settings.defaultAgent] in sync with the installation's kind.
  void setDefaultAgentInstallation(AgentKind? kind, String? installationId) {
    state = state.copyWith(
      defaultAgent: kind,
      clearDefaultAgent: installationId == null,
      defaultAgentInstallationId: installationId,
    );
    _save();
  }

  void setLauncherHotkey(String hotkeyJson) {
    state = state.copyWith(launcherHotkeyJson: hotkeyJson);
    _save();
  }

  void setLauncherHotkeyEnabled(bool enabled) {
    state = state.copyWith(launcherHotkeyEnabled: enabled);
    _save();
  }

  void setNewSessionPermission(AgentKind kind, PermissionMode mode) {
    state = state.withPermissions(
      kind,
      state.permissionsFor(kind).copyWith(newSessions: mode),
    );
    _save();
  }

  void setExistingSessionPermission(AgentKind kind, PermissionMode mode) {
    state = state.withPermissions(
      kind,
      state.permissionsFor(kind).copyWith(existingSessions: mode),
    );
    _save();
  }

  void _save() => ref.read(settingsRepositoryProvider).save(state);
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, Settings>(SettingsController.new);
