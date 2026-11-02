import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/session_chat_source.dart'
    show ChatsShownOutsideGroups, chatsShownOutsideGroupsProvider;

/// Counts [child], a conversation drawn outside any workbench group, as on
/// screen: the dashboard's peek and the bot's panel, which the poll of a
/// transcript cannot otherwise see.
class ChatShownOutsideGroups extends ConsumerStatefulWidget {
  const ChatShownOutsideGroups({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ChatShownOutsideGroups> createState() => _ShownChatState();
}

class _ShownChatState extends ConsumerState<ChatShownOutsideGroups> {
  late final ChatsShownOutsideGroups _shown;
  var _counted = false;

  @override
  void initState() {
    super.initState();
    _shown = ref.read(chatsShownOutsideGroupsProvider.notifier);
    // After the frame: a provider is not changed while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shown.add();
      _counted = true;
    });
  }

  @override
  void dispose() {
    if (_counted) {
      final shown = _shown;
      Future.microtask(shown.remove);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
