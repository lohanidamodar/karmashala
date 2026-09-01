import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/browser_pane_controller.dart';
import '../domain/element_capture.dart';

/// The browser pane: attach to the Chrome the developer already has open,
/// drive it, and point at an element to send it to an agent.
///
/// The pane exists so this feature is usable without an agent in the loop —
/// "pick this element and tell Claude about it" is the flow that makes driving
/// a real browser worth more than a screenshot.
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
        if (state.error != null)
          _ErrorBanner(
            message: state.error!,
            onDismiss: _controller.clearError,
          ),
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

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Tooltip(
              message: state.isConnected
                  ? '${state.connection}\n${state.title}\n${state.url}'
                  : 'Karmashala attaches to a browser started with '
                        '--remote-debugging-port=${state.port}, and only '
                        'launches its own (on a throwaway profile) when '
                        'nothing is listening.',
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          if (state.isConnected)
            TextButton(onPressed: onDisconnect, child: const Text('Detach'))
          else
            FilledButton.tonal(
              onPressed: state.isBusy ? null : onConnect,
              child: Text('Attach · ${state.port}'),
            ),
        ],
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
            style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'localhost:3000',
              prefixIcon: Icon(AppIcons.globe, size: 15),
              prefixIconConstraints: BoxConstraints(minWidth: 30),
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Go',
          icon: const Icon(AppIcons.caretRight, size: 16),
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
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, Insets.sm, 0),
    child: Row(
      children: [
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isDense: true,
              isExpanded: true,
              value: state.tabs.any((t) => t.id == state.currentTargetId)
                  ? state.currentTargetId
                  : null,
              hint: const Text('Tab'),
              items: [
                for (final tab in state.tabs)
                  DropdownMenuItem(
                    value: tab.id,
                    child: Text(
                      tab.title.isEmpty ? tab.url : tab.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
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
          icon: const Icon(AppIcons.arrowsClockwise, size: 15),
          onPressed: () =>
              ref.read(browserPaneControllerProvider.notifier).refreshTabs(),
        ),
      ],
    ),
  );
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
      child: Row(
        children: [
          if (picking)
            FilledButton.tonalIcon(
              onPressed: controller.cancelPick,
              icon: const Icon(AppIcons.x, size: 15),
              label: const Text('Cancel pick'),
            )
          else
            FilledButton.tonalIcon(
              onPressed: state.isConnected && !state.isBusy
                  ? controller.pickElement
                  : null,
              icon: const Icon(AppIcons.target, size: 15),
              label: const Text('Pick element'),
            ),
          const Spacer(),
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(
        Insets.sm,
        Insets.sm,
        Insets.xs,
        Insets.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            AppIcons.warningCircle,
            size: 15,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: SelectableText(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.x, size: 13),
            onPressed: onDismiss,
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
      return PanePlaceholder(
        message: switch (state.status) {
          BrowserPaneStatus.disconnected =>
            'Attach to a browser to drive it from here.\n\n'
                'Karmashala attaches to a Chrome started with '
                '--remote-debugging-port=${state.port} — your window, your '
                'logins — and only launches one of its own, on a throwaway '
                'profile, if nothing is listening.',
          BrowserPaneStatus.picking =>
            'Point at an element in the browser and click it.\n'
                'Escape cancels.',
          _ =>
            'Connected. Pick an element to capture its HTML, styles and a '
                'cropped screenshot, then send it to a session.',
        },
      );
    }
    return _CapturePreview(capture: capture, state: state);
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
        SelectableText(
          capture.selector,
          style: const TextStyle(fontFamily: kMonoFamily, fontSize: 11.5),
        ),
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
                icon: const Icon(AppIcons.paperPlaneRight, size: 15),
                label: const Text('Send to session'),
              ),
            ),
            const SizedBox(width: Insets.sm),
            IconButton.outlined(
              tooltip: 'Copy the bundle',
              icon: const Icon(AppIcons.copy, size: 15),
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
        Text('WHAT WILL BE SENT', style: theme.textTheme.labelSmall),
        const SizedBox(height: Insets.xs),
        SelectableText(
          ref.read(browserPaneControllerProvider.notifier).capturePrompt() ??
              '',
          style: const TextStyle(fontFamily: kMonoFamily, fontSize: 11),
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
