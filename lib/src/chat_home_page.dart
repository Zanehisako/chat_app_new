import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_models.dart';
import 'chat_repository.dart';

class ChatHomePage extends StatefulWidget {
  const ChatHomePage({super.key, required this.repository, this.onSignOut});

  final ChatRepository repository;
  final Future<void> Function()? onSignOut;

  @override
  State<ChatHomePage> createState() => _ChatHomePageState();
}

class _ChatHomePageState extends State<ChatHomePage> {
  late Stream<List<ChatThread>> _threadsStream;
  ChatThread? _selectedThread;
  final _messageController = TextEditingController();
  final _searchController = TextEditingController();
  final List<ChatThread> _startedThreads = [];
  final List<ChatMessage> _localMessages = [];
  String _query = '';
  bool _isSending = false;
  bool _isCompactConversationOpen = false;

  @override
  void initState() {
    super.initState();
    _threadsStream = widget.repository.watchThreads();
  }

  @override
  void didUpdateWidget(covariant ChatHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _threadsStream = widget.repository.watchThreads();
      _selectedThread = null;
      _startedThreads.clear();
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ChatThread>>(
      stream: _threadsStream,
      initialData: widget.repository.isConnected
          ? const []
          : widget.repository.threads,
      builder: (context, snapshot) {
        final threads = _mergeThreads(snapshot.data ?? const []);
        final selectedThread = _selectedThreadFor(threads);

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 840;

            return Scaffold(
              body: SafeArea(
                child: isWide
                    ? _buildWideLayout(threads, selectedThread)
                    : _buildCompactLayout(threads, selectedThread),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildWideLayout(
    List<ChatThread> threads,
    ChatThread? selectedThread,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: _ThreadList(
            threads: _filteredThreads(threads),
            selectedThread: selectedThread,
            isConnected: widget.repository.isConnected,
            searchController: _searchController,
            onSearchChanged: _setQuery,
            onThreadSelected: _selectThread,
            onNewChat: _openNewChat,
            onSignOut: _requestSignOut,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selectedThread == null
              ? const _EmptyConversationPane()
              : _buildConversation(
                  thread: selectedThread,
                  showBackButton: false,
                ),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(
    List<ChatThread> threads,
    ChatThread? selectedThread,
  ) {
    if (!_isCompactConversationOpen) {
      return _ThreadList(
        threads: _filteredThreads(threads),
        selectedThread: selectedThread,
        isConnected: widget.repository.isConnected,
        searchController: _searchController,
        onSearchChanged: _setQuery,
        onThreadSelected: _selectCompactThread,
        onNewChat: _openNewChat,
        onSignOut: _requestSignOut,
      );
    }

    return selectedThread == null
        ? const _EmptyConversationPane()
        : _buildConversation(thread: selectedThread, showBackButton: true);
  }

  Widget _buildConversation({
    required ChatThread thread,
    required bool showBackButton,
  }) {
    return _ConversationPane(
      key: ValueKey(thread.id),
      thread: thread,
      repository: widget.repository,
      localMessages: _localMessages
          .where((message) => message.threadId == thread.id)
          .toList(),
      messageController: _messageController,
      isSending: _isSending,
      showBackButton: showBackButton,
      onBackToInbox: _showCompactInbox,
      onSend: () => _sendMessage(thread),
      onSignOut: _requestSignOut,
    );
  }

  List<ChatThread> _filteredThreads(List<ChatThread> threads) {
    final normalizedQuery = _query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return threads;
    }

    return threads.where((thread) {
      return thread.title.toLowerCase().contains(normalizedQuery) ||
          thread.subtitle.toLowerCase().contains(normalizedQuery);
    }).toList();
  }

  List<ChatThread> _mergeThreads(List<ChatThread> threads) {
    final merged = {for (final thread in threads) thread.id: thread};

    for (final thread in _startedThreads) {
      merged.putIfAbsent(thread.id, () => thread);
    }

    return merged.values.toList();
  }

  ChatThread? _selectedThreadFor(List<ChatThread> threads) {
    final selected = _selectedThread;
    if (selected != null) {
      for (final thread in threads) {
        if (thread.id == selected.id) {
          return thread;
        }
      }
    }

    if (threads.isEmpty) {
      return selected;
    }
    return threads.first;
  }

  void _setQuery(String value) {
    setState(() {
      _query = value;
    });
  }

  void _selectThread(ChatThread thread) {
    setState(() {
      _selectedThread = thread;
    });
  }

  void _selectCompactThread(ChatThread thread) {
    setState(() {
      _selectedThread = thread;
      _isCompactConversationOpen = true;
    });
  }

  Future<void> _openNewChat() async {
    final user = await showDialog<ChatUser>(
      context: context,
      builder: (context) => _NewChatDialog(repository: widget.repository),
    );

    if (user == null || !mounted) {
      return;
    }

    await _startChatWith(user);
  }

  Future<void> _startChatWith(ChatUser user) async {
    try {
      final thread = await widget.repository.startDirectConversation(user);
      if (!mounted) {
        return;
      }

      setState(() {
        _startedThreads.removeWhere((item) => item.id == thread.id);
        _startedThreads.insert(0, thread);
        _selectedThread = thread;
        _isCompactConversationOpen = true;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start that conversation.')),
      );
    }
  }

  void _showCompactInbox() {
    setState(() {
      _isCompactConversationOpen = false;
    });
  }

  void _requestSignOut() {
    _signOut();
  }

  Future<void> _signOut() async {
    final signOut = widget.onSignOut;
    if (signOut == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active session to sign out.')),
      );
      return;
    }

    try {
      await signOut();
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not sign out. Please try again.')),
      );
    }
  }

  Future<void> _sendMessage(ChatThread selectedThread) async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) {
      return;
    }

    _messageController.clear();
    FocusScope.of(context).unfocus();

    if (!widget.repository.isConnected) {
      setState(() {
        _localMessages.add(
          ChatMessage(
            id: 'local-${DateTime.now().microsecondsSinceEpoch}',
            threadId: selectedThread.id,
            senderId: ChatSeed.localUserId,
            senderName: 'You',
            body: text,
            createdAt: DateTime.now(),
            isMine: true,
            deliveryState: DeliveryState.sent,
          ),
        );
      });
      return;
    }

    setState(() {
      _isSending = true;
    });

    try {
      await widget.repository.sendMessage(
        conversationId: selectedThread.id,
        body: text,
      );
    } catch (_) {
      if (mounted) {
        _messageController.text = text;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message not sent. Check Supabase auth and RLS.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog({required this.repository});

  final ChatRepository repository;

  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<ChatUser> _users = const [];
  String _query = '';
  String? _error;
  bool _isLoading = false;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.edit_square),
          SizedBox(width: 10),
          Text('New message'),
        ],
      ),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const Key('new-chat-search'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _scheduleSearch,
              decoration: const InputDecoration(
                hintText: 'Search people',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(child: _buildResults(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    if (_query.trim().isEmpty) {
      return Center(
        child: Text(
          'Search by name.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    if (_users.isEmpty) {
      return Center(
        child: Text(
          widget.repository.isConnected
              ? 'No users found. Make sure profiles exist in Supabase.'
              : 'No users found.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _users.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final user = _users[index];
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: _UserAvatar(user: user),
          title: Text(user.displayName),
          subtitle: user.email == null ? null : Text(user.email!),
          onTap: () => Navigator.of(context).pop(user),
        );
      },
    );
  }

  void _scheduleSearch(String value) {
    _debounce?.cancel();

    setState(() {
      _query = value;
      _error = null;
      _users = const [];
      _isLoading = value.trim().isNotEmpty;
    });

    if (value.trim().isEmpty) {
      return;
    }

    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => _searchUsers(value),
    );
  }

  Future<void> _searchUsers(String query) async {
    final requestId = ++_requestId;

    try {
      final users = await widget.repository.searchUsers(query);
      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _users = users;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _error = 'Could not search users.';
        _isLoading = false;
      });
    }
  }
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({required this.user});

  final ChatUser user;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        user.avatarLabel,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList({
    required this.threads,
    required this.selectedThread,
    required this.isConnected,
    required this.searchController,
    required this.onSearchChanged,
    required this.onThreadSelected,
    required this.onNewChat,
    required this.onSignOut,
  });

  final List<ChatThread> threads;
  final ChatThread? selectedThread;
  final bool isConnected;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<ChatThread> onThreadSelected;
  final VoidCallback onNewChat;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Messages',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'New chat',
                  onPressed: onNewChat,
                  icon: const Icon(Icons.edit_square),
                ),
                IconButton(
                  tooltip: 'Sign out',
                  onPressed: onSignOut,
                  icon: const Icon(Icons.logout),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: searchController,
              onChanged: onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search chats',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            _BackendStatusPill(isConnected: isConnected),
            const SizedBox(height: 16),
            Expanded(
              child: threads.isEmpty
                  ? const _EmptyThreadList()
                  : ListView.separated(
                      itemCount: threads.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final thread = threads[index];
                        return _ThreadTile(
                          thread: thread,
                          isSelected: thread.id == selectedThread?.id,
                          onTap: () => onThreadSelected(thread),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyThreadList extends StatelessWidget {
  const _EmptyThreadList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No conversations yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _BackendStatusPill extends StatelessWidget {
  const _BackendStatusPill({required this.isConnected});

  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isConnected
        ? const Color(0xFF127A74)
        : const Color(0xFFB5661B);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isConnected ? Icons.cloud_done : Icons.data_object,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isConnected
                  ? 'Supabase realtime connected'
                  : 'Local preview data',
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.thread,
    required this.isSelected,
    required this.onTap,
  });

  final ChatThread thread;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedColor = theme.colorScheme.primary.withValues(alpha: 0.1);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? selectedColor : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.28)
                : theme.dividerColor.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            _Avatar(thread: thread, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        thread.lastActive,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (thread.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        _UnreadBadge(count: thread.unreadCount),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyConversationPane extends StatelessWidget {
  const _EmptyConversationPane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Text(
        'Start a new conversation.',
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    super.key,
    required this.thread,
    required this.repository,
    required this.localMessages,
    required this.messageController,
    required this.isSending,
    required this.showBackButton,
    required this.onBackToInbox,
    required this.onSend,
    required this.onSignOut,
  });

  final ChatThread thread;
  final ChatRepository repository;
  final List<ChatMessage> localMessages;
  final TextEditingController messageController;
  final bool isSending;
  final bool showBackButton;
  final VoidCallback onBackToInbox;
  final VoidCallback onSend;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: Row(
            children: [
              if (showBackButton)
                IconButton(
                  tooltip: 'Back to chats',
                  onPressed: onBackToInbox,
                  icon: const Icon(Icons.arrow_back),
                ),
              _Avatar(thread: thread, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: thread.isOnline
                              ? const Color(0xFF17A36B)
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            thread.isOnline ? 'Online' : 'Away',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Call',
                onPressed: () {},
                icon: const Icon(Icons.call_outlined),
              ),
              IconButton(
                tooltip: 'Video',
                onPressed: () {},
                icon: const Icon(Icons.videocam_outlined),
              ),
              IconButton(
                tooltip: 'Sign out',
                onPressed: onSignOut,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<ChatMessage>>(
            stream: repository.watchMessages(thread.id),
            builder: (context, snapshot) {
              final messages = [
                ...(snapshot.data ?? ChatSeed.messagesFor(thread.id)),
                ...localMessages,
              ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

              if (messages.isEmpty) {
                return const _EmptyMessageList();
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  return _MessageBubble(message: messages[index]);
                },
              );
            },
          ),
        ),
        _MessageComposer(
          controller: messageController,
          isSending: isSending,
          onSend: onSend,
        ),
      ],
    );
  }
}

class _EmptyMessageList extends StatelessWidget {
  const _EmptyMessageList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Text(
        'No messages yet.',
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMine = message.isMine;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(8),
                topRight: const Radius.circular(8),
                bottomLeft: Radius.circular(isMine ? 8 : 2),
                bottomRight: Radius.circular(isMine ? 2 : 8),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Column(
                crossAxisAlignment: isMine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!isMine) ...[
                    Text(
                      message.senderName,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: textColor.withValues(alpha: 0.74),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    message.body,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: textColor,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: textColor.withValues(alpha: 0.72),
                        ),
                      ),
                      if (isMine) ...[
                        const SizedBox(width: 6),
                        Icon(
                          message.deliveryState == DeliveryState.seen
                              ? Icons.done_all
                              : Icons.done,
                          size: 15,
                          color: textColor.withValues(alpha: 0.72),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.isSending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Attach',
              onPressed: () {},
              icon: const Icon(Icons.add),
            ),
            Expanded(
              child: TextField(
                key: const Key('message-composer'),
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(hintText: 'Message'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: isSending ? null : onSend,
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
              ),
              child: isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.thread, required this.size});

  final ChatThread thread;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: thread.accentColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            thread.avatarLabel,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.34,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (thread.isOnline)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: const Color(0xFF17A36B),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

String _formatTime(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
