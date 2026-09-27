import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/device_ports.dart';
import 'device_hold.dart';
import 'package:karmashala_ui/picking.dart';
import '../application/device_app_actions.dart';
import 'package:karmashala_devices/karmashala_devices.dart';

/// **Put a build on the device, start it, stop it** — beside the live view,
/// through [DeviceAppActions]: the same claim the tools take, naming holders.
class DeviceAppControls extends ConsumerStatefulWidget {
  const DeviceAppControls({required this.device, this.pickFile, super.key});

  /// The device the pane is showing, or null when there is none.
  final AndroidDevice? device;

  /// A seam for the host's file dialog. On Windows the picker runs on the
  /// isolate's own thread — see `karmashala_ui/picking.dart` — so a test never
  /// opens it.
  final Future<XFile?> Function()? pickFile;

  @override
  ConsumerState<DeviceAppControls> createState() => _DeviceAppControlsState();
}

/// A path as the host hands it over — Explorer's *Copy as path* and PowerShell
/// wrap it in double quotes, taken off here rather than left as a user's rule.
String unquotePath(String value) {
  final trimmed = value.trim();
  return trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')
      ? trimmed.substring(1, trimmed.length - 1).trim()
      : trimmed;
}

class _DeviceAppControlsState extends ConsumerState<DeviceAppControls> {
  final _appId = TextEditingController();
  final _buildPath = TextEditingController();
  DeviceActionOutcome<Object?>? _outcome;
  bool _busy = false;

  @override
  void dispose() {
    _appId.dispose();
    _buildPath.dispose();
    super.dispose();
  }

  bool get _ready => (widget.device?.isReady ?? false) && !_busy;

  /// Acts; on a device an agent holds, asks the person first — in the
  /// holder's words — and acts anyway only when they say so.
  Future<void> _run(
    Future<DeviceActionOutcome<Object?>> Function(
      String deviceId,
      bool override,
    )
    act,
  ) async {
    final serial = widget.device?.serial;
    if (serial == null) return;
    setState(() => _busy = true);
    var outcome = await act(serial, false);
    if (outcome.heldBy != null && mounted) {
      final anyway = await confirmActOnHeldDevice(context, outcome.problem!);
      if (anyway && mounted) outcome = await act(serial, true);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = outcome;
    });
  }

  /// The path in the field, or null when there is none to act on.
  String? get _typedPath {
    final path = unquotePath(_buildPath.text);
    return path.isEmpty ? null : path;
  }

  Future<void> _install() async {
    // The field wins when it has something in it: falling back to the picker
    // would put a dialog in front of a frozen window's only working control.
    final path = _typedPath ?? (await (widget.pickFile ?? _browse)())?.path;
    if (path == null) return;
    await _run(
      (serial, override) => ref
          .read(deviceAppActionsProvider)
          .install(deviceId: serial, path: path, override: override),
    );
  }

  Future<XFile?> _browse() => pickOneFile(
    context: context,
    what: 'a build to install',
    startNear: _buildPath.text,
    acceptedTypeGroups: const [
      // Both platforms' artifacts in one group: the driver refuses the wrong
      // one by name, which is a better message than a picker that hid it.
      XTypeGroup(label: 'App builds', extensions: ['apk', 'app']),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appId = _appId.text.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.xs,
            Insets.sm,
            Insets.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    // A package, not a download: down is "to this computer"
                    // everywhere else in the pane, and this goes to the device.
                    icon: const Icon(AppIcons.package, size: Chrome.iconAction),
                    // The ellipsis is a promise that a dialog is coming, so it
                    // goes when there is a path to act on and nothing will open.
                    label: Text(_typedPath == null ? 'Install…' : 'Install'),
                    onPressed: _ready ? _install : null,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: TextField(
                      key: const Key('device-install-path'),
                      controller: _buildPath,
                      style: theme.textTheme.bodySmall,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'or paste a path to an .apk or .app',
                      ),
                      onChanged: (_) => setState(() {}),
                      // Enter installs. A path typed into a window that is not
                      // repainting still reaches this.
                      onSubmitted: (_) => _ready ? _install() : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.xs),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('device-app-id'),
                      controller: _appId,
                      style: theme.textTheme.bodySmall,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'applicationId, e.g. com.example.app',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Launch this app',
                    icon: const Icon(
                      AppIcons.rocketLaunch,
                      size: Chrome.iconAction,
                    ),
                    onPressed: _ready && appId.isNotEmpty
                        ? () => _run(
                            (serial, override) => ref
                                .read(deviceAppActionsProvider)
                                .launch(
                                  deviceId: serial,
                                  appId: appId,
                                  override: override,
                                ),
                          )
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Force-stop this app',
                    icon: const Icon(
                      AppIcons.prohibit,
                      size: Chrome.iconAction,
                    ),
                    onPressed: _ready && appId.isNotEmpty
                        ? () => _run(
                            (serial, override) => ref
                                .read(deviceAppActionsProvider)
                                .terminate(
                                  deviceId: serial,
                                  appId: appId,
                                  override: override,
                                ),
                          )
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_outcome case final outcome?) _Answer(outcome: outcome),
      ],
    );
  }
}

/// The driver's answer, with the age of it.
class _Answer extends ConsumerWidget {
  const _Answer({required this.outcome});

  final DeviceActionOutcome<Object?> outcome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final now = ref.watch(deviceClockProvider).nowUtc();
    final said = outcome.ok
        ? switch (outcome.value) {
            final InstalledApp app => app.note ?? 'Installed ${app.path}',
            final LaunchedApp app =>
              app.note ??
                  'Launched ${app.appId}${app.pid == null ? '' : ' (pid ${app.pid})'}',
            _ => 'Force-stopped',
          }
        : outcome.problem!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.sm),
      child: SelectableText(
        // The age is not decoration: an install that succeeded four minutes ago
        // says nothing about what is on the device now.
        '$said · ${describeDriveAge(now.difference(outcome.at))}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: outcome.ok
              ? theme.colorScheme.onSurfaceVariant
              : semantic.attention,
        ),
      ),
    );
  }
}
