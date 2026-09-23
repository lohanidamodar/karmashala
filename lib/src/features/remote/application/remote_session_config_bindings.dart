import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_model_catalog_providers.dart';
import '../../sessions/application/session_launcher.dart';
import 'remote_binding_support.dart';

/// `session.options`: the same models and modes the desktop's chips offer,
/// less any mode that removes every prompt — that one needs the desktop's own
/// confirmation and a relaunch.
Future<RemoteSessionOptions> remoteSessionOptions(
  Ref ref,
  String sessionId,
) async {
  final native = _nativeSession(ref, sessionId);
  final launcher = ref.read(sessionLauncherProvider);
  final model = launcher.effectiveModelFor(native);
  final permission = launcher.effectivePermissionFor(native);
  final agentId = model?.descriptor?.id;
  final models = agentId == null
      ? const AgentModelSupport.unsupported()
      : ref.read(agentModelSupportProvider(agentId));
  final modes = permission?.descriptor?.launch.permission;

  return RemoteSessionOptions(
    sessionId: sessionId,
    models: [
      if (models.isSupported)
        for (final m in models.models)
          RemoteChoice(id: m.id, label: m.label, summary: m.summary),
    ],
    modelId: model == null || model.inherited ? null : model.modelId,
    modelDefaultLabel: model?.defaultModelId == null
        ? null
        : models.modelFor(model!.defaultModelId)?.label ?? model.defaultModelId,
    permissions: modes == null ? const [] : _safeSelections(modes),
    permissionId: permission == null || permission.inherited
        ? null
        : permission.selection.canonical,
    permissionDefaultLabel: permission == null || modes == null
        ? null
        : describeSelection(modes, permission.selection),
  );
}

/// `session.configure`: recorded as the desktop's chips record it, and moved in
/// the running session where the agent allows it.
Future<RemoteConfigureOutcome> remoteConfigureSession(
  Ref ref,
  String sessionId, {
  ({String? id})? model,
  ({String? id})? permission,
}) async {
  final native = _nativeSession(ref, sessionId);
  final launcher = ref.read(sessionLauncherProvider);
  var outcome = RemoteConfigureOutcome.recorded;

  if (model != null) {
    final set = launcher.setModel(native, model.id);
    outcome = set.switchedNow
        ? RemoteConfigureOutcome.now
        : switch (set.deferral) {
            ModelDeferral.openedPicker => RemoteConfigureOutcome.pickerOpened,
            ModelDeferral.busy when launcher.turnWillEnd(native) =>
              RemoteConfigureOutcome.afterTurn,
            _ => RemoteConfigureOutcome.recorded,
          };
  }

  if (permission != null) {
    final modes = launcher
        .effectivePermissionFor(native)
        ?.descriptor
        ?.launch
        .permission;
    final selection = permission.id == null
        ? null
        : PermissionSelection.parse(permission.id!);
    if (modes != null && selection != null && modes.isDangerous(selection)) {
      throw const RemoteApiRefusal(
        ErrorCode.notPermitted,
        'a mode that removes every prompt can only be chosen on the desktop',
      );
    }
    launcher.setPermissionMode(native, selection);
    outcome = switch (await launcher.switchPermissionLive(native)) {
      LivePermissionOutcome.switched => RemoteConfigureOutcome.now,
      LivePermissionOutcome.held => RemoteConfigureOutcome.afterTurn,
      LivePermissionOutcome.openedPicker => RemoteConfigureOutcome.pickerOpened,
      _ => RemoteConfigureOutcome.recorded,
    };
  }
  return outcome;
}

String _nativeSession(Ref ref, String sessionId) {
  final native = resolveRemoteSession(ref, sessionId).native;
  if (native == null) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'imported history has no running session to change',
    );
  }
  return native.id;
}

/// Every selection the phone may choose: each combination of the axes, as
/// the agent itself resolves it, less the dangerous ones.
List<RemoteChoice> _safeSelections(AgentPermissionSupport modes) {
  if (!modes.isKnown) return const [];
  var combos = <Map<String, String>>[{}];
  for (final axis in modes.axes) {
    combos = [
      for (final partial in combos)
        for (final value in axis.values) {...partial, axis.id: value.id},
    ];
  }
  final seen = <String>{};
  return [
    for (final combo in combos)
      if (modes.normalise(PermissionSelection(combo)) case final selection
          when !modes.isDangerous(selection) && seen.add(selection.canonical))
        RemoteChoice(
          id: selection.canonical,
          label: describeSelection(modes, selection),
          summary: describeSelectionDetail(modes, selection) ?? '',
        ),
  ];
}
