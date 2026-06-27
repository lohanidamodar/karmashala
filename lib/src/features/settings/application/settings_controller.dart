import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../agents/domain/agent_kind.dart';
import '../data/settings_repository.dart';
import '../domain/app_theme_mode.dart';
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

  void setDefaultAgent(AgentKind? kind) {
    state = state.copyWith(defaultAgent: kind, clearDefaultAgent: kind == null);
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
