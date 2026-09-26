import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/logging/diagnostics_bootstrap.dart';
import '../../../core/logging/diagnostics_providers.dart';
import '../data/settings_repository.dart';
import '../domain/app_theme_mode.dart';
import '../domain/diagnostics_settings.dart';
import '../domain/editor_settings.dart';
import '../domain/settings.dart';
import '../domain/usage_limit_settings.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(appPreferencesProvider)),
);

/// Holds the user [Settings], persisting every change at the server — and
/// taking the settings another client wrote there.
class SettingsController extends Notifier<Settings> {
  @override
  Settings build() {
    final repository = ref.watch(settingsRepositoryProvider);
    _raw = repository.raw();
    final changes = ref.watch(appPreferencesProvider).changes.listen((_) {
      final raw = repository.raw();
      if (raw == _raw) return;
      _raw = raw;
      state = SettingsRepository.decode(raw);
    });
    ref.onDispose(changes.cancel);
    return SettingsRepository.decode(_raw);
  }

  /// What is stored, as last read or written here: a change is one only when
  /// it differs, so this client's own writes never come back as news.
  String? _raw;

  /// Turns debug mode on or off: the root logger moves between `ALL` and
  /// `INFO`, and the Logs panel appears with it.
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

  /// Pushes the persisted diagnostics preferences at the live sinks — on every
  /// change, and once at bootstrap so a restart restores them.
  void applyDiagnostics() => applyDiagnosticsSettings(
    ref.read(diagnosticsProvider),
    debugMode: state.debugMode,
    fileLevel: state.logVerbosity.level,
    logToFile: state.logToFile,
    bufferSize: state.logBufferSize,
  );

  /// Turns Notes on or off. Off hides it; the notes stay in the database.
  void setNotesEnabled(bool value) {
    state = state.copyWith(notesEnabled: value);
    _save();
  }

  /// Whether the Explorer folds away an empty saved section — a filter, not a
  /// deletion: it comes back when something lands in it.
  void setHideEmptySections(bool value) {
    state = state.copyWith(hideEmptySections: value);
    _save();
  }

  /// Which agents the Explorer shows; empty is "every agent". Written sorted,
  /// so a reordered identical choice is not a change `Settings ==` reports.
  void setExplorerAgentFilter(Set<String> agentIds) {
    state = state.copyWith(explorerAgentFilter: agentIds.toList()..sort());
    _save();
  }

  /// Leaves a side-panel surface off the rail, or puts it back. It stays
  /// reachable from the View menu, quick open and its chord either way.
  void setSidePanelSurfaceHidden(String surfaceId, {required bool hidden}) {
    final current = state.hiddenSidePanelSurfaces;
    if (current.contains(surfaceId) == hidden) return;
    state = state.copyWith(
      hiddenSidePanelSurfaces: hidden
          ? ([...current, surfaceId]..sort())
          : [
              for (final id in current)
                if (id != surfaceId) id,
            ],
    );
    _save();
  }

  /// Every surface back on the rail — the default, so this is also the reset.
  void showAllSidePanelSurfaces() {
    if (state.hiddenSidePanelSurfaces.isEmpty) return;
    state = state.copyWith(hiddenSidePanelSurfaces: const []);
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

  /// Which categories to leave running — the full set, never a toggle.
  void setSimulatorSlimmingKept(List<String> ids) {
    state = state.copyWith(simulatorSlimmingKept: ids);
    _save();
  }

  void setAndroidSlimming(bool value) {
    state = state.copyWith(androidSlimming: value);
    _save();
  }

  /// Which Android categories to apply — the full set, never a toggle.
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

  /// Opens every one of [nodeIds] that is folded, so a row beneath them can be
  /// seen. Writes nothing when they are all open already — this runs whenever
  /// the workbench moves, and a settings write per `cd` would be absurd.
  void revealExplorerNodes(Iterable<String> nodeIds) {
    final collapsed = state.collapsedExplorerNodes;
    if (collapsed.isEmpty) return;
    final folded = nodeIds.toSet();
    if (!collapsed.any(folded.contains)) return;
    state = state.copyWith(
      collapsedExplorerNodes: [
        for (final id in collapsed)
          if (!folded.contains(id)) id,
      ],
    );
    _save();
  }

  /// Folds an Explorer row away, or opens it again. Absent means expanded, so
  /// a machine that appears later opens rather than inheriting somebody's fold.
  void toggleExplorerNodeCollapsed(String nodeId) {
    final collapsed = state.collapsedExplorerNodes;
    state = state.copyWith(
      collapsedExplorerNodes: collapsed.contains(nodeId)
          ? [
              for (final id in collapsed)
                if (id != nodeId) id,
            ]
          : [...collapsed, nodeId],
    );
    _save();
  }

  /// Narrows the Explorer to one machine; empty is every machine.
  void setExplorerEnvironmentScope(String environmentId) {
    if (state.explorerEnvironmentScope == environmentId) return;
    state = state.copyWith(explorerEnvironmentScope: environmentId);
    _save();
  }

  /// See [Settings.explorerContextScope] for the spelling.
  void setExplorerContextScope(String scope) {
    if (state.explorerContextScope == scope) return;
    state = state.copyWith(explorerContextScope: scope);
    _save();
  }

  void setExplorerProjectDetails(bool value) {
    if (state.explorerProjectDetails == value) return;
    state = state.copyWith(explorerProjectDetails: value);
    _save();
  }

  void setCompactDensity(bool value) {
    state = state.copyWith(compactDensity: value);
    _save();
  }

  void setEditorWordWrap(bool value) {
    state = state.copyWith(editorWordWrap: value);
    _save();
  }

  void setUsageLimitBehavior(UsageLimitBehavior value) {
    state = state.copyWith(usageLimitBehavior: value);
    _save();
  }

  void setResumeMessage(String value) {
    state = state.copyWith(resumeMessage: value.trim());
    _save();
  }

  /// Remembers what a resume of [agentId] last said, for the next dialog.
  void rememberResumeMessage(String agentId, String message) {
    if (state.resumeMessages[agentId] == message) return;
    state = state.withResumeMessage(agentId, message);
    _save();
  }

  void setEditorAutoSave(EditorAutoSave value) {
    state = state.copyWith(editorAutoSave: value);
    _save();
  }

  /// Clamped to what [EditorAutoSave.afterDelay] can sensibly mean.
  void setEditorAutoSaveDelay(int milliseconds) {
    state = state.copyWith(
      editorAutoSaveDelayMs: milliseconds.clamp(
        kMinEditorAutoSaveDelayMs,
        kMaxEditorAutoSaveDelayMs,
      ),
    );
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

  void togglePinnedProject(String projectId) {
    final pinned = [...state.pinnedProjectIds];
    if (!pinned.remove(projectId)) pinned.add(projectId);
    state = state.copyWith(pinnedProjectIds: pinned);
    _save();
  }

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

  /// Which dialog "Browse…" opens. Null hands the answer back to the platform.
  void setUseInAppFilePicker(bool? inApp) {
    state = state.copyWith(
      useInAppFilePicker: inApp,
      clearUseInAppFilePicker: inApp == null,
    );
    _save();
  }

  /// Whether every file browser shows hidden entries.
  void setShowHiddenFiles(bool value) {
    state = state.copyWith(showHiddenFiles: value);
    _save();
  }

  void setDefaultAgent(String? agentId) {
    state = state.copyWith(
      defaultAgent: agentId,
      clearDefaultAgent: agentId == null,
    );
    _save();
  }

  /// Sets the default installation, keeping [Settings.defaultAgent] in sync.
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

  /// Whether a focused pane hands [label] to the app or the shell, over the
  /// default in `shellChords`.
  void setTerminalChordClaimed(String label, bool claimed) {
    state = state.copyWith(
      terminalChordOverrides: {...state.terminalChordOverrides, label: claimed},
    );
    _save();
  }

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

  /// Sets the per-agent default model; a null [modelId] passes no flag at all.
  void setDefaultModel(String agentId, String? modelId) {
    state = state.withDefaultModel(agentId, modelId);
    _save();
  }

  /// Sets the `flutter` for [environmentId]; a blank [path] puts it back on
  /// PATH. Measures nothing — `FlutterSdkReadings.build` watches this map.
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

  /// The quit question's answers, as it will use them without asking.
  void setQuitAnswers({
    required bool asks,
    required bool reopens,
    required bool keepsHostSessions,
  }) {
    state = state.copyWith(
      quitAsks: asks,
      quitReopens: reopens,
      quitKeepsHostSessions: keepsHostSessions,
    );
    _save();
  }

  void setQuitAsks(bool value) {
    state = state.copyWith(quitAsks: value);
    _save();
  }

  /// Applies to the *next* pane: a running shell cannot change its owner.
  void setHostBackedLocalPanes(bool value) {
    state = state.copyWith(hostBackedLocalPanes: value);
    _save();
  }

  /// Whether an agent Karmashala launches may update itself in that session.
  /// Written concretely, so a machine that later flips its platform default
  /// keeps the user's explicit choice. Applies to the *next* launch.
  void setLetAgentsUpdateThemselves(bool value) {
    state = state.copyWith(letAgentsUpdateThemselves: value);
    _save();
  }

  void setTerminalThemeSource(String? id) {
    state = state.copyWith(
      terminalThemeSource: id,
      clearTerminalThemeSource: id == null,
    );
    _save();
  }

  void setLocalRelayPort(int port) {
    state = state.copyWith(localRelayPort: port);
    _save();
  }

  /// [_raw] first: the copy tells its listeners synchronously, and this
  /// write must not read as another client's.
  void _save() {
    final raw = _raw = SettingsRepository.encode(state);
    ref.read(settingsRepositoryProvider).saveRaw(raw);
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, Settings>(SettingsController.new);
