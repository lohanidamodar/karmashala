import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/browser_pane_controller.dart';
import 'package:karmashala_browser/browser.dart';
import 'browser_console.dart';
import 'browser_viewport_shot.dart';
import 'pane_status_row.dart';

/// The browser pane: attach to the Chrome the developer already has open,
/// drive it, and point at an element to send it to an agent.
class BrowserPane extends ConsumerStatefulWidget {
  const BrowserPane({super.key});

  @override
  ConsumerState<BrowserPane> createState() => _BrowserPaneState();
}

class _BrowserPaneState extends ConsumerState<BrowserPane> {
  final _url = TextEditingController();
  bool _urlEdited = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  BrowserPaneController get _controller =>
      ref.read(browserPaneControllerProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(browserPaneControllerProvider);
    // Follow the page unless the user is part-way through typing an address.
    if (!_urlEdited && state.url.isNotEmpty && _url.text != state.url) {
      _url.text = state.url;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ConnectionBar(
          state: state,
          onConnect: () => _controller.connect(),
          onDisconnect: _controller.disconnect,
        ),
        const Divider(height: 1),
        _AddressBar(
          controller: _url,
          enabled: !state.isBusy,
          onChanged: (_) => _urlEdited = true,
          onSubmit: () {
            _urlEdited = false;
            _controller.navigate(_url.text);
          },
        ),
        if (state.tabs.length > 1) _TabPicker(state: state),
        const Divider(height: 1),
        _Actions(state: state),
        if (state.error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            child: DesktopErrorBanner(error, onDismiss: _controller.clearError),
          ),
        // Under the actions and above the picture: the two questions a person
        // asks a page they are debugging, over the same service the tools use.
        BrowserConsole(state: state),
        Expanded(child: _Body(state: state)),
      ],
    );
  }
}

/// Says exactly what we are attached to, or that we are attached to nothing.
class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({
    required this.state,
    required this.onConnect,
    required this.onDisconnect,
  });

  final BrowserPaneState state;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final (colour, label) = switch (state.status) {
      BrowserPaneStatus.disconnected => (
        theme.colorScheme.outline,
        'Not connected',
      ),
      BrowserPaneStatus.connecting => (semantic.working, 'Connecting…'),
      BrowserPaneStatus.busy => (semantic.working, 'Working…'),
      BrowserPaneStatus.picking => (
        theme.colorScheme.tertiary,
        'Click an element in the browser…',
      ),
      BrowserPaneStatus.connected => (
        theme.colorScheme.primary,
        state.connection ?? 'Connected',
      ),
    };

    return PaneStatusRow(
      color: colour,
      label: label,
      tooltip: state.isConnected
          ? '${state.connection}\n${state.title}\n${state.url}'
          : 'Karmashala attaches to a browser already listening on '
                'port ${state.port}. Since Chrome 136 that takes '
                '--remote-debugging-port=${state.port} together with '
                'a --user-data-dir of its own; the flag alone is '
                'ignored on the default profile. It only launches its '
                'own (on a throwaway profile) when nothing is '
                'listening.',
      action: state.isConnected
          ? TextButton(onPressed: onDisconnect, child: const Text('Detach'))
          : FilledButton.tonal(
              onPressed: state.isBusy ? null : onConnect,
              child: Text('Attach · ${state.port}'),
            ),
    );
  }
}

class _AddressBar extends StatelessWidget {
  const _AddressBar({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, Insets.sm, 0),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            onChanged: onChanged,
            onSubmitted: (_) => onSubmit(),
            style: MonoStyles.body,
            // No `border` or `contentPadding` of its own: a bare `OutlineInputBorder()`
            // takes Material's radius and stroke instead of the app's. The theme says both.
            decoration: const InputDecoration(
              hintText: 'localhost:3000',
              prefixIcon: Icon(AppIcons.globe, size: Chrome.icon),
              prefixIconConstraints: BoxConstraints(minWidth: 30),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Go',
          icon: const Icon(AppIcons.caretRight),
          onPressed: enabled ? onSubmit : null,
        ),
      ],
    ),
  );
}

/// One page is driven at a time; this chooses which.
class _TabPicker extends ConsumerWidget {
  const _TabPicker({required this.state});

  final BrowserPaneState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, Insets.sm, 0),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              // `DropdownButton` is Material 2, and `dropdownMenuTheme` reaches only
              // Material 3's `DropdownMenu` — left alone it takes Material's own defaults.
              child: DropdownButton<String>(
                isDense: true,
                isExpanded: true,
                style: theme.textTheme.bodySmall,
                iconSize: Chrome.icon,
                value: state.tabs.any((t) => t.id == state.currentTargetId)
                    ? state.currentTargetId
                    : null,
                hint: Text('Tab', style: theme.textTheme.bodySmall),
                items: [
                  for (final tab in state.tabs)
                    DropdownMenuItem(
                      value: tab.id,
                      child: Text(
                        tab.title.isEmpty ? tab.url : tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: state.isBusy
                    ? null
                    : (id) {
                        if (id != null) {
                          ref
                              .read(browserPaneControllerProvider.notifier)
                              .selectTab(id);
                        }
                      },
              ),
            ),
          ),
          IconButton(
            tooltip: 'Refresh tabs',
            icon: const Icon(AppIcons.arrowsClockwise),
            onPressed: () =>
                ref.read(browserPaneControllerProvider.notifier).refreshTabs(),
          ),
        ],
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.state});

  final BrowserPaneState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(browserPaneControllerProvider.notifier);
    final picking = state.status == BrowserPaneStatus.picking;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      // A Wrap, not a Row with a Spacer: in a 240px panel at 1.3x text the pick
      // button alone is wider than the row.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        children: [
          if (picking)
            FilledButton.tonalIcon(
              onPressed: controller.cancelPick,
              icon: const Icon(AppIcons.x),
              label: const Text('Cancel pick'),
            )
          else
            FilledButton.tonalIcon(
              onPressed: state.isConnected && !state.isBusy
                  ? controller.pickElement
                  : null,
              icon: const Icon(AppIcons.target),
              label: const Text('Pick element'),
            ),
          if (state.capture != null)
            TextButton(
              onPressed: controller.clearCapture,
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.state});

  final BrowserPaneState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capture = state.capture;
    if (capture == null) {
      // A pick's crop wins when there is one: it is the more specific answer,
      // and it is the one the user asked for by pointing at something.
      final shot = ref.watch(browserViewportShotProvider);
      if (!shot.isEmpty) return BrowserViewportShotView(shot: shot);
      return PanePlaceholder(
        message: switch (state.status) {
          BrowserPaneStatus.disconnected =>
            'Attach to a browser to drive it from here.',
          BrowserPaneStatus.picking =>
            'Point at an element in the browser and click it.\n'
                'Escape cancels.',
          _ =>
            'Connected. Pick an element to capture its HTML, styles and a '
                'cropped screenshot, then send it to a session.',
        },
        action: state.status == BrowserPaneStatus.disconnected
            ? _HowAttachingWorks(port: state.port)
            : null,
      );
    }
    return _CapturePreview(capture: capture, state: state);
  }
}

/// The long answer to "why did it launch its own browser", folded until asked:
/// open, it is taller than a 240px panel.
class _HowAttachingWorks extends StatefulWidget {
  const _HowAttachingWorks({required this.port});

  final int port;

  @override
  State<_HowAttachingWorks> createState() => _HowAttachingWorksState();
}

class _HowAttachingWorksState extends State<_HowAttachingWorks> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final port = widget.port;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(
            _open ? AppIcons.caretDown : AppIcons.caretRight,
            size: Chrome.iconAction,
          ),
          label: const Text('How attaching works'),
        ),
        if (_open)
          Text(
            'Karmashala attaches to a Chrome already listening on port $port '
            '— your window, your logins. Since Chrome 136 that takes '
            '--remote-debugging-port=$port with a --user-data-dir of its own; '
            'on your normal profile the flag is ignored.\n\n'
            'If nothing is listening, Karmashala launches its own on a '
            'throwaway profile. The status line above says which you got.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// The picked element: what it looks like, what it is, and where it can go.
class _CapturePreview extends ConsumerWidget {
  const _CapturePreview({required this.capture, required this.state});

  final ElementCapture capture;
  final BrowserPaneState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sessionId = ref.watch(selectedSessionIdProvider);
    final png = capture.screenshotPng;

    return ListView(
      padding: const EdgeInsets.all(Insets.sm),
      children: [
        if (png != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Padding(
                padding: const EdgeInsets.all(Insets.xs),
                child: Image.memory(png, fit: BoxFit.contain),
              ),
            ),
          ),
        const SizedBox(height: Insets.sm),
        SelectableText(capture.description, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        SelectableText(capture.selector, style: MonoStyles.small),
        const SizedBox(height: 2),
        Text(
          '${capture.box} · ${capture.computedStyles.length} computed '
          'properties',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.sm),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: sessionId == null
                    ? null
                    : () => _send(context, ref, sessionId),
                icon: const Icon(AppIcons.paperPlaneRight),
                label: const Text('Send to session'),
              ),
            ),
            const SizedBox(width: Insets.sm),
            IconButton.outlined(
              tooltip: 'Copy the bundle',
              icon: const Icon(AppIcons.copy),
              onPressed: () => _copy(context, ref),
            ),
          ],
        ),
        if (sessionId == null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              'Open a session to send this to an agent.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (state.sentToSession != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              state.sentToSession!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        const SizedBox(height: Insets.sm),
        const Divider(height: 1),
        const SizedBox(height: Insets.sm),
        const EyebrowLabel('What will be sent'),
        const SizedBox(height: Insets.xs),
        SelectableText(
          ref.read(browserPaneControllerProvider.notifier).capturePrompt() ??
              '',
          style: MonoStyles.small,
        ),
      ],
    );
  }

  Future<void> _send(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
  ) async {
    final controller = ref.read(browserPaneControllerProvider.notifier);
    final prompt = controller.capturePrompt();
    if (prompt == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(sessionActionsProvider).continueSession(sessionId, prompt);
      controller.noteSent('Sent to the open session.');
    } on Object catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _copy(BuildContext context, WidgetRef ref) async {
    final prompt = ref
        .read(browserPaneControllerProvider.notifier)
        .capturePrompt();
    if (prompt == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: prompt));
    messenger?.showSnackBar(
      const SnackBar(content: Text('Element bundle copied.')),
    );
  }
}
