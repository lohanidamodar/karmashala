import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../explorer/application/explorer_actions.dart';
import '../../sessions/application/session_chat_source.dart'
    show composersHoldingTextProvider;
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/overview_batch.dart';
import '../application/overview_board.dart';
import '../application/overview_on_screen.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import 'overview_batch_bar.dart';
import 'overview_filters.dart';
import 'overview_hybrid.dart';
import 'overview_peek.dart';
import 'overview_pins.dart';
import 'overview_queue_card.dart';
import 'overview_resume_picker.dart';
import 'overview_triage.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../../sessions/presentation/prompt_cards/question_prompt_card.dart';
import '../timeline/presentation/overview_timeline_view.dart';
import '../../pipelines/presentation/pipeline_run_card.dart';
import '../../pipelines/presentation/pipeline_run_dialog.dart';
import '../../todos/application/todos_providers.dart'
    show openTodoCountProvider;
import '../../todos/presentation/todos_page.dart';

part 'overview_tab_view/tab_chrome.dart';
part 'overview_tab_view/board_body.dart';

/// **The Overview tab**: what is going on across all the work, as a Board
/// (state by project or machine) or a Timeline. Built only while its tab is
/// on screen; on the phone it is a page under More.
class OverviewTabView extends ConsumerWidget {
  const OverviewTabView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    // The tab's own width, not the window's: the pinned dashboard can sit in a
    // narrow group of a wide window.
    builder: (context, box) => _build(context, ref, box.maxWidth),
  );

  Widget _build(BuildContext context, WidgetRef ref, double width) {
    final view = ref.watch(overviewPrefsProvider.select((p) => p.view));
    // The phone's Dashboard tab: no name over it, its header the one row.
    final rootTab = PaneTitleOverride.maybeOf(context) != null;
    // Words beside Resume and New session only where the header has room
    // for them and the view switch together.
    final narrow = width < WidthClass.expandedMin;
    final actions = [
      // The phone's way to its todos, one tap from home.
      if (rootTab) const OverviewTodosButton(),
      _ResumeButton(narrow: narrow),
      _NewSessionButton(narrow: narrow),
      if (width >= WidthClass.expandedMin) const _RunPipelineButton(),
      if (view == OverviewView.board) ...[
        const OverviewFilterButton(),
        // The keys need a keyboard; a thumb has none to press.
        if (!UiDensity.of(context).isTouch)
          IconButton(
            key: const ValueKey('overview-keys-button'),
            tooltip: 'Keyboard shortcuts (?)',
            onPressed: () => showOverviewKeys(context),
            icon: const Icon(AppIcons.keyboard),
          ),
      ],
    ];
    return _OnScreen(
      child: WorkbenchTabScaffold(
        icon: AppIcons.squaresFour,
        title: 'Agent dashboard',
        oneRowStrip: rootTab,
        controls: [
          CompactSegmented<OverviewView>(
            key: const ValueKey('overview-view'),
            segments: const [
              ButtonSegment(value: OverviewView.board, label: Text('Board')),
              ButtonSegment(
                value: OverviewView.timeline,
                label: Text('Timeline'),
              ),
            ],
            selected: view,
            onChanged: ref.read(overviewPrefsProvider.notifier).setView,
          ),
        ],
        actions: rootTab
            ? [
                // Compact, so the segment and every action share the row.
                Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(visualDensity: VisualDensity.compact),
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ]
            : actions,
        body: switch (view) {
          OverviewView.board => const _BoardBody(),
          OverviewView.timeline => const _TimelineBody(),
        },
      ),
    );
  }
}

/// Whether the keyboard is in a text field.
bool overviewTyping() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

/// The least width mission control keeps beside a docked peek.
const double kOverviewBoardMinWidth = 720;

/// From this width the peek docks beside the board, resizable; below it, it
/// floats over the board so the cards keep their columns.
const double kOverviewPeekDocksFrom = 1280;

/// The peek's width when it opens, and the bounds a drag keeps it in.
const double kOverviewPeekWidth = 520;
const double _peekMinWidth = 360;
const double _peekMaxWidth = 820;

/// How the peek sits beside the board at a width.
enum OverviewPeekMode { docked, overlay, sheet }

/// The peek's place at [width]: a full-screen sheet on a phone, over the
/// board below [kOverviewPeekDocksFrom], docked from it.
OverviewPeekMode overviewPeekModeAt(double width) =>
    width < WidthClass.mediumMin
    ? OverviewPeekMode.sheet
    : width < kOverviewPeekDocksFrom
    ? OverviewPeekMode.overlay
    : OverviewPeekMode.docked;

/// The Timeline, opening a bar's session as the Board does. Its log outlives
/// the sessions it draws, so a bar can name one that has since been deleted:
/// that is said, not treated as a failure.
class _TimelineBody extends ConsumerWidget {
  const _TimelineBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) => OverviewTimelineView(
    onOpenSession: (id) => openTimelineSession(context, ref, id),
  );
}

/// Opens session [id] from the Timeline: its tab when the row is still here,
/// otherwise a line saying it was deleted and its history stays.
Future<void> openTimelineSession(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final actions = ref.read(explorerActionsProvider);
  final imported = ref.read(importedSessionsProvider).getById(id);
  final ExplorerResult result;
  if (ref.read(sessionsDataProvider).getById(id) != null) {
    result = await actions.openNative(id);
  } else if (imported != null) {
    result = await actions.openImported(imported);
  } else {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'That session was deleted. Its history stays on the Timeline.',
        ),
      ),
    );
    return;
  }
  if (!result.isFailure) showWorkbench?.call();
  final message = result.message;
  if (message != null) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
