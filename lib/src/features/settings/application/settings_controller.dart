import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/logging/diagnostics_bootstrap.dart';
import '../../../core/logging/diagnostics_providers.dart';
import '../data/settings_repository.dart';
import '../domain/app_theme_mode.dart';
import '../domain/diagnostics_settings.dart';
import '../domain/relay_mode.dart';
import '../domain/settings.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

/// Holds the user [Settings], persisting every change.
class SettingsController extends Notifier<Settings> {
  @override
  Settings build() => ref.watch(settingsRepositoryProvider).load();

  /// Turns debug mode on or off. Raises the root logger to `ALL` while on and
  /// puts it back to `INFO` when off; also what makes the Logs panel appear.
  void setDebugMode(bool value) {
    state = state.copyWith(debugMode: value);
    _save();
    applyDiagnostics();
  }

  void setLogVerbosity(LogVerbosity value) {
    state = state.copyWith(logVerbosity: value);
    _save();
    applyDiagnostics();
  }

  void setLogToFile(bool value) {
    state = state.copyWith(logToFile: value);
    _save();
    applyDiagnostics();
  }

  void setLogBufferSize(int value) {
    state = state.copyWith(logBufferSize: value);
    _save();
    applyDiagnostics();
  }

  /// Pushes the persisted diagnostics preferences at the live sinks. Called on
  /// every change, and once at bootstrap so a restart restores them.
  void applyDiagnostics() => applyDiagnosticsSettings(
    ref.read(diagnosticsProvider),
    debugMode: state.debugMode,
    fileLevel: state.logVerbosity.level,
    logToFile: state.logToFile,
    bufferSize: state.logBufferSize,
  );

  /// Turns the Notes feature on or off. Off hides the affordance and the
  /// panel surface; the notes themselves stay in the database.
  void setNotesEnabled(bool value) {
    state = state.copyWith(notesEnabled: value);
    _save();
  }

  /// Whether the Explorer folds away a saved section holding nothing.
  ///
  /// A filter, not a deletion: a hidden section is still saved, still matches,
  /// and comes back the moment something lands in it.
  void setHideEmptySections(bool value) {
    state = state.copyWith(hideEmptySections: value);
    _save();
  }

  /// Which agents the Explorer shows, as `AgentDescriptor.id`s.
  ///
  /// Empty is "every agent" — see [AgentFilter], where unticking the last one
  /// is what returns the sidebar to the unfiltered list. Written sorted so two
  /// identical choices made in a different order are one settings value and not
  /// two, which is what keeps `Settings ==` from reporting a change nobody
  /// made.
  void setExplorerAgentFilter(Set<String> agentIds) {
    state = state.copyWith(explorerAgentFilter: agentIds.toList()..sort());
    _save();
  }

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

  void setSimulatorSlimming(bool value) {
    state = state.copyWith(simulatorSlimming: value);
    _save();
  }

  /// Records which categories to leave running. Takes the full set each time
  /// rather than a toggle, so the caller cannot get the two out of step.
  void setSimulatorSlimmingKept(List<String> ids) {
    state = state.copyWith(simulatorSlimmingKept: ids);
    _save();
  }

  void setAndroidSlimming(bool value) {
    state = state.copyWith(androidSlimming: value);
    _save();
  }

  /// Records which Android categories to apply. Takes the full set each time
  /// rather than a toggle, so the caller cannot get the two out of step.
  void setAndroidSlimmingEnabled(List<String> ids) {
    state = state.copyWith(androidSlimmingEnabled: ids);
    _save();
  }

  void setAndroidEmulatorGpu(String modeId) {
    state = state.copyWith(androidEmulatorGpu: modeId);
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

  /// Sets the overall UI text scale, clamped to the supported 90%–150%.
  void setUiTextScale(double scale) {
    state = state.copyWith(
      uiTextScale: scale.clamp(
        Settings.minUiTextScale,
        Settings.maxUiTextScale,
      ),
    );
    _save();
  }

  /// Sets the terminal grid's font size, clamped to a usable range.
  void setTerminalFontSize(double size) {
    state = state.copyWith(
      terminalFontSize: size.clamp(
        Settings.minTerminalFontSize,
        Settings.maxTerminalFontSize,
      ),
    );
    _save();
  }

  /// Nudges the terminal font size — what Ctrl+= / Ctrl+- are wired to.
  void adjustTerminalFontSize(double delta) =>
      setTerminalFontSize(state.terminalFontSize + delta);

  /// Puts the terminal font size back to the shipped default (Ctrl+0).
  void resetTerminalFontSize() =>
      setTerminalFontSize(Settings.defaultTerminalFontSize);

  void setWindowSize(double width, double height) {
    state = state.copyWith(windowWidth: width, windowHeight: height);
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

  void setDefaultAgent(String? agentId) {
    state = state.copyWith(
      defaultAgent: agentId,
      clearDefaultAgent: agentId == null,
    );
    _save();
  }

  /// Sets the default to a specific installation (or clears it). Keeps
  /// [Settings.defaultAgent] in sync with the installation's agent id.
  void setDefaultAgentInstallation(String? agentId, String? installationId) {
    state = state.copyWith(
      defaultAgent: agentId,
      clearDefaultAgent: installationId == null,
      defaultAgentInstallationId: installationId,
    );
    _save();
  }

  void setLauncherHotkey(String hotkeyJson) {
    state = state.copyWith(launcherHotkeyJson: hotkeyJson);
    _save();
  }

  /// Says whether a focused terminal pane hands [label] to the app or to the
  /// shell, overriding the default declared in `shellChords`.
  void setTerminalChordClaimed(String label, bool claimed) {
    state = state.copyWith(
      terminalChordOverrides: {...state.terminalChordOverrides, label: claimed},
    );
    _save();
  }

  /// Drops every override, putting the whole skip-list back to its defaults.
  void resetTerminalChordOverrides() {
    state = state.copyWith(terminalChordOverrides: const {});
    _save();
  }

  void setLauncherHotkeyEnabled(bool enabled) {
    state = state.copyWith(launcherHotkeyEnabled: enabled);
    _save();
  }

  void setNewSessionPermission(String agentId, String mode) {
    state = state.withPermissions(
      agentId,
      state.permissionsFor(agentId).copyWith(newSessions: mode),
    );
    _save();
  }

  void setExistingSessionPermission(String agentId, String mode) {
    state = state.withPermissions(
      agentId,
      state.permissionsFor(agentId).copyWith(existingSessions: mode),
    );
    _save();
  }

  /// Sets the per-agent default model, or with a null [modelId] hands the agent
  /// back to choosing for itself — no model flag at all.
  ///
  /// Null stays a first-class answer here rather than being widened to "some
  /// model": it is what every session ran under before this setting existed and
  /// is still the shipped default. See `Settings.defaultModels`.
  void setDefaultModel(String agentId, String? modelId) {
    state = state.withDefaultModel(agentId, modelId);
    _save();
  }

  /// Sets the `flutter` executable for [environmentId], or with a blank [path]
  /// puts that environment back on its own PATH.
  ///
  /// Measures nothing, and invalidates nothing from here: a save must not
  /// block on a process, and the readings drop themselves when this map
  /// changes — `FlutterSdkReadings.build` watches it, which keeps the rule
  /// beside the readings rather than in every writer of the setting.
  void setFlutterSdkPath(String environmentId, String? path) {
    state = state.withFlutterSdkPath(environmentId, path);
    _save();
  }

  void setShellIntegrationEnabled(bool value) {
    state = state.copyWith(shellIntegrationEnabled: value);
    _save();
  }

  void setRestoreLivePanes(bool value) {
    state = state.copyWith(restoreLivePanes: value);
    _save();
  }

  /// Sets, or with `null` clears, the imported terminal colour theme.
  void setTerminalThemeSource(String? id) {
    state = state.copyWith(
      terminalThemeSource: id,
      clearTerminalThemeSource: id == null,
    );
    _save();
  }

  void setRemoteAccessEnabled(bool value) {
    state = state.copyWith(remoteAccessEnabled: value);
    _save();
  }

  /// Sets, or with `null` clears, the relay the remote-access host dials.
  void setRemoteRelayUrl(String? url) {
    state = state.copyWith(
      remoteRelayUrl: url,
      clearRemoteRelayUrl: url == null,
    );
    _save();
  }

  /// Chooses between the embedded local relay and a hosted one.
  void setRemoteRelayMode(RelayMode mode) {
    state = state.copyWith(remoteRelayMode: mode);
    _save();
  }

  void setLocalRelayPort(int port) {
    state = state.copyWith(localRelayPort: port);
    _save();
  }

  void _save() => ref.read(settingsRepositoryProvider).save(state);
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, Settings>(SettingsController.new);
