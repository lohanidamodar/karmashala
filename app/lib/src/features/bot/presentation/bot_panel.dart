import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/dialogs.dart' show showConfirmDialog;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openSettingsTab;
import '../../../core/capabilities/capabilities.dart';
import '../../notes/application/composer_draft.dart';
import '../../sessions/presentation/message_composer.dart';
import '../../sessions/presentation/session_transcript_view.dart';
import '../../sessions/presentation/shown_chat.dart';
import '../../settings/presentation/settings_catalog.dart'
    show SettingsSectionId;
import '../application/bot_providers.dart';
import 'bot_agent_switcher.dart';
import 'bot_approvals.dart';

/// Where the box of a conversation not yet begun parks its words.
const _unsentDraft = 'bot-unsent';

/// What the empty panel offers to put in the box, for the person to finish.
const _samples = [
  'Resume the last active sessions in ',
  'What is waiting for me?',
  'Which sessions are running?',
  'Start a session to ',
];

/// **The bot's conversation**: its header over whichever of its states holds.
/// A panel on a desktop and a sheet on a phone are this, framed differently.
/// Opening it reads the bot and creates nothing.
class BotPanelView extends ConsumerWidget {
  const BotPanelView({required this.onClose, this.phone = false, super.key});

  final VoidCallback onClose;

  /// In the phone's sheet: the box is held while a prompt is open, as on the
  /// phone's session page.
  final bool phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Semantics(
    container: true,
    label: 'Bot',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BotHeader(onClose: onClose),
        const Divider(height: 1),
        Expanded(
          child: _BotBody(phone: phone, onClose: onClose),
        ),
      ],
    ),
  );
}

class _BotBody extends ConsumerWidget {
  const _BotBody({required this.phone, required this.onClose});

  final bool phone;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(botStateProvider);
    final connected = ref.watch(botConnectedProvider);
    final failure = ref.watch(botReadFailureProvider);
    final sending = ref.watch(botFirstSendProvider);
    final id = state?.session?.id;

    final Widget body;
    if (state == null) {
      body = !connected
          ? const _BotReason(notConnected)
          : failure != null
          ? _BotReason('The bot could not be read: $failure')
          : const Center(child: InlineSpinner(size: InlineSpinnerSize.large));
    } else if (id != null && !sending) {
      body = ChatShownOutsideGroups(
        child: SessionTranscriptView(
          key: ValueKey('bot-chat:$id'),
          sessionId: id,
          resumesInBackground: true,
          holdForPrompt: phone,
          bot: true,
          footerLead: const BotApprovalStrip(),
        ),
      );
    } else if (state.agents.isEmpty) {
      body = _NoAgent(onClose: onClose);
    } else {
      body = const _BotEmpty();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state != null && !connected)
          const PaneNoticeBar(
            icon: AppIcons.warning,
            tone: NoticeTone.attention,
            message: notConnected,
          ),
        if (state?.notice case final notice?)
          PaneNoticeBar(
            key: const ValueKey('bot-notice'),
            icon: AppIcons.info,
            message: notice,
          ),
        Expanded(child: body),
      ],
    );
  }
}

/// Why the bot cannot be reached: the button's words, and the panel's when
/// the link goes while it is open.
const notConnected =
    'Not connected to the server, so the bot cannot be reached.';

/// One plain reason, in the middle of the panel.
class _BotReason extends StatelessWidget {
  const _BotReason(this.words, {this.action});

  final String words;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            words,
            textAlign: TextAlign.center,
            style: UiDensity.of(context).muted(Theme.of(context)),
          ),
          if (action case final action?) ...[
            const SizedBox(height: Insets.md),
            action,
          ],
        ],
      ),
    ),
  );
}

class _NoAgent extends ConsumerWidget {
  const _NoAgent({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _BotReason(
    'No agent the bot can run on is installed on this server. It needs an '
    'agent with a chat form.',
    action: OutlinedButton(
      key: const ValueKey('bot-open-agents'),
      onPressed: () {
        onClose();
        openSettingsTab(ref, section: SettingsSectionId.agents);
      },
      child: const Text('Open Agents'),
    ),
  );
}

/// Nothing said yet: one line on what the bot does, a few requests to start
/// from, and the box. The row is made by the first message, not by this.
class _BotEmpty extends ConsumerStatefulWidget {
  const _BotEmpty();

  @override
  ConsumerState<_BotEmpty> createState() => _BotEmptyState();
}

class _BotEmptyState extends ConsumerState<_BotEmpty> {
  final _box = TextEditingController();
  final _focus = ValueNotifier<int>(0);
  late final ParkedDrafts _parked;

  @override
  void initState() {
    super.initState();
    _parked = ref.read(parkedDraftsProvider);
    // After the frame: a conversation cleared under the person parks its
    // draft as it goes, which is after this mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _box.text.isNotEmpty) return;
      final bots = ref.read(botSessionsProvider).ids;
      for (final id in [...bots, _unsentDraft]) {
        final words = _parked.take(id)?.text;
        if (words == null) continue;
        _put(words);
        return;
      }
    });
  }

  @override
  void dispose() {
    _parked.park(_unsentDraft, _box.text);
    _box.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _put(String words) {
    _box.value = TextEditingValue(
      text: words,
      selection: TextSelection.collapsed(offset: words.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(capabilitiesProvider);
    final refusal = !caps.maySend
        ? kPromptNotGranted
        : !caps.manageBot
        ? kStartNotGranted
        : null;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The bot finds, resumes, starts and messages your sessions, '
                  'and answers questions about them.',
                  key: const ValueKey('bot-empty'),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: Insets.md),
                Wrap(
                  spacing: Insets.xs,
                  runSpacing: Insets.xs,
                  children: [
                    for (final sample in _samples)
                      ActionChip(
                        label: Text(sample.trimRight()),
                        tooltip: 'Put this in the box',
                        onPressed: refusal != null
                            ? null
                            : () {
                                _put(sample);
                                _focus.value++;
                              },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        MessageComposer(
          key: const ValueKey('bot-first-message'),
          controller: _box,
          focusRequests: _focus,
          takesKeysOnOpen: () => true,
          attaches: false,
          enabled: refusal == null,
          hintText: refusal ?? 'Ask the bot…',
          onSend: ref.read(botActionsProvider).sendFirst,
        ),
      ],
    );
  }
}

class _BotHeader extends ConsumerWidget {
  const _BotHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: Insets.md,
        end: Insets.xs,
        top: Insets.xs,
        bottom: Insets.xs,
      ),
      child: Row(
        children: [
          Icon(
            AppIcons.robot,
            size: density.icon,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: Insets.sm),
          Text(
            'Bot',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(width: Insets.sm),
          const Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: BotAgentSwitcher(),
            ),
          ),
          const _BotOverflow(),
          IconButton(
            key: const ValueKey('bot-close'),
            tooltip: 'Close the bot',
            visualDensity: density.controlDensity,
            iconSize: density.icon,
            icon: const Icon(AppIcons.x),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// ⋯: Clear conversation, asked first.
class _BotOverflow extends ConsumerWidget {
  const _BotOverflow();

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final actions = ref.read(botActionsProvider);
    final yes = await showConfirmDialog(
      context,
      title: 'Clear the conversation?',
      message:
          'The next message starts a new conversation. Sessions the bot '
          'started keep running as ordinary sessions, and approvals still '
          'waiting expire. What the bot keeps in its memory file stays.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!yes) return;
    try {
      await actions.clear();
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = UiDensity.of(context);
    final state = ref.watch(botStateProvider);
    final running = ref.watch(botTurnRunningProvider);
    final mayClear = ref.watch(capabilitiesProvider.select((c) => c.manageBot));
    final hasRow = state?.session != null;
    return Builder(
      builder: (anchor) => IconButton(
        key: const ValueKey('bot-overflow'),
        tooltip: 'More',
        visualDensity: density.controlDensity,
        iconSize: density.icon,
        icon: const Icon(AppIcons.dotsThree),
        onPressed: () async {
          final picked = await showDesktopMenuUnder<Symbol>(anchor, [
            DesktopMenuItem(
              value: #clear,
              label: running
                  ? 'Clear conversation (wait for the turn to end)'
                  : 'Clear conversation…',
              icon: AppIcons.broom,
              destructive: true,
              enabled: hasRow && mayClear && !running,
            ),
          ]);
          if (picked == #clear && anchor.mounted) {
            await _clear(anchor, ref);
          }
        },
      ),
    );
  }
}
