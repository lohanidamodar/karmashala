import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/file_picking.dart';
import '../application/device_app_actions.dart';
import '../domain/android_device.dart';
import '../domain/device_claim.dart' show describeDriveAge;
import '../domain/device_driver.dart';

/// **Put a build on the device, start it, stop it** — beside the live view.
///
/// The three verbs a manual test needs between two attempts, and the reason
/// they were worth surfacing: an agent could cold-restart the app under the
/// picture and the person watching it could not.
///
/// Everything goes through [DeviceAppActions], which is the layer
/// `DeviceControlTools` itself sits on — the same fleet, the same capability
/// check, the same [DeviceClaims]. So a device another session is driving
/// refuses these buttons exactly as it refuses the tools, **naming the holder**
/// rather than failing quietly or, worse, succeeding and breaking somebody's
/// run.
///
/// The answer line under the row carries its age (§19). "Installed" was true
/// when the driver said it and is not a standing claim about the device now.
class DeviceAppControls extends ConsumerStatefulWidget {
  const DeviceAppControls({required this.device, this.pickFile, super.key});

  /// The device the pane is showing, or null when there is none.
  final AndroidDevice? device;

  /// A seam for the host's file dialog. On Windows the picker runs on the
  /// isolate's own thread — see `file_picking.dart` — so a test must never
  /// reach the real one.
  final Future<XFile?> Function()? pickFile;

  @override
  ConsumerState<DeviceAppControls> createState() => _DeviceAppControlsState();
}

class _DeviceAppControlsState extends ConsumerState<DeviceAppControls> {
  final _appId = TextEditingController();
  DeviceActionOutcome<Object?>? _outcome;
  bool _busy = false;

  @override
  void dispose() {
    _appId.dispose();
    super.dispose();
  }

  bool get _ready => (widget.device?.isReady ?? false) && !_busy;

  Future<void> _run(
    Future<DeviceActionOutcome<Object?>> Function(String deviceId) act,
  ) async {
    final serial = widget.device?.serial;
    if (serial == null) return;
    setState(() => _busy = true);
    final outcome = await act(serial);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = outcome;
    });
  }

  Future<void> _install() async {
    final file = await (widget.pickFile ?? _browse)();
    if (file == null) return;
    await _run(
      (serial) => ref
          .read(deviceAppActionsProvider)
          .install(deviceId: serial, path: file.path),
    );
  }

  Future<XFile?> _browse() => pickOneFile(
    what: 'a build to install',
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
          child: Row(
            children: [
              TextButton.icon(
                icon: const Icon(
                  AppIcons.downloadSimple,
                  size: Chrome.iconAction,
                ),
                label: const Text('Install…'),
                onPressed: _ready ? _install : null,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: TextField(
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
                icon: const Icon(AppIcons.playCircle, size: Chrome.iconAction),
                onPressed: _ready && appId.isNotEmpty
                    ? () => _run(
                        (serial) => ref
                            .read(deviceAppActionsProvider)
                            .launch(deviceId: serial, appId: appId),
                      )
                    : null,
              ),
              IconButton(
                tooltip: 'Force-stop this app',
                icon: const Icon(AppIcons.stopCircle, size: Chrome.iconAction),
                onPressed: _ready && appId.isNotEmpty
                    ? () => _run(
                        (serial) => ref
                            .read(deviceAppActionsProvider)
                            .terminate(deviceId: serial, appId: appId),
                      )
                    : null,
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
    final now = ref.watch(clockProvider).nowUtc();
    final said = outcome.ok
        ? switch (outcome.value) {
            final InstalledApp app => app.note ?? 'Installed ${app.path}',
            final LaunchedApp app =>
              app.note ?? 'Launched ${app.appId}${app.pid == null ? '' : ' (pid ${app.pid})'}',
            _ => 'Force-stopped',
          }
        : outcome.problem!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        0,
        Insets.md,
        Insets.sm,
      ),
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
