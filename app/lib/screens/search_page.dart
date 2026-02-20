import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';
import '../conversation_store.dart';

/// A single message in the conversation
class ChatMessage {
  final String role; // "user" or "assistant"
  final String text;
  final List<String> retrievedDocs;
  final bool isLoading;
  final bool wasCancelled;

  const ChatMessage({
    required this.role,
    required this.text,
    this.retrievedDocs = const [],
    this.isLoading = false,
    this.wasCancelled = false,
  });

  ChatMessage copyWith({
    String? text,
    List<String>? retrievedDocs,
    bool? isLoading,
    bool? wasCancelled,
  }) {
    return ChatMessage(
      role: role,
      text: text ?? this.text,
      retrievedDocs: retrievedDocs ?? this.retrievedDocs,
      isLoading: isLoading ?? this.isLoading,
      wasCancelled: wasCancelled ?? this.wasCancelled,
    );
  }
}

/// This is the chat page. The user interacts with the model by typing in
/// the input field or clicking one of the suggestion chips.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();

  /// Request the LLM to initialise itself (used in intro)
  static void requestLlmPreinit() {
    debugPrint('Requesting LLM initialization');
    _SearchPageState.platform.invokeMethod("ensureInit");
  }

  /// Wait for the LLM to be initialised (like request preinit but also waits)
  static Future<void> waitForLlmInit() {
    return _SearchPageState.platform.invokeMethod("ensureInit");
  }
}

class _SearchPageState extends State<SearchPage> {
  final List<ChatMessage> _messages = [];

  static const platform = MethodChannel(
    "io.github.mzsfighters.mam_ai/request_generation",
  );
  static const latestMessageStream = EventChannel(
    "io.github.mzsfighters.mam_ai/latest_message",
  );
  StreamSubscription? _latestMessageSubscription;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _useRetrieval = true;
  bool _isGenerating = false;
  final ConversationStore _store = ConversationStore();
  String? _currentConversationId;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey();
  final GlobalKey<_ConversationDrawerState> _drawerKey = GlobalKey();

  // Background generation state — active when the user navigates away while
  // generation is still running. Incoming events are routed here instead of
  // _messages so the response is captured and saved without interruption.
  bool _backgroundGenerating = false;
  String? _backgroundConvId;
  String _backgroundConvTitle = '';
  List<Map<String, String>> _backgroundMessages = [];

  // IDs of conversations that finished generating while the user was elsewhere.
  final Set<String> _unreadConvIds = {};

  static const _modelContextTokens = 32000; // Gemma 3n E4B context window
  static const _charsPerToken = 4; // rough estimate for English text
  static const _reservedChars =
      4000; // system prompt + retrieved docs + current query + response
  static const _historyCharThreshold =
      (_modelContextTokens * _charsPerToken) - _reservedChars;

  /// Returns (history, wasTruncated). Drops oldest turns until under threshold.
  (List<Map<String, String>>, bool) _buildHistory() {
    var history = _messages
        .where((m) => !m.isLoading && m.text.isNotEmpty)
        .map((m) => {"role": m.role, "text": m.text})
        .toList();

    var truncated = false;
    while (history.isNotEmpty) {
      final chars = history.fold<int>(0, (sum, m) => sum + m["text"]!.length);
      if (chars <= _historyCharThreshold) break;
      if (history.length == 1) {
        // Even a single message exceeds the threshold — drop all history.
        history = [];
        truncated = true;
        break;
      }
      history = history.sublist(1); // drop oldest message
      truncated = true;
    }

    // After size-based truncation, the oldest remaining entry may be a model
    // turn (its paired user turn was just dropped). Drop leading model turns
    // so buildPrompt() always receives a history that starts with a user turn.
    while (history.isNotEmpty && history.first["role"] != "user") {
      history = history.sublist(1);
    }

    if (truncated) {
      debugPrint(
        '[WARN] History truncated: oldest turns dropped to fit context window',
      );
    }
    return (history, truncated);
  }

  /// Request the model to generate a response — calls into Android code
  Future<void> _generateResponse(String prompt) async {
    if (prompt.trim().isEmpty) return;
    // If a previous conversation is still generating in the background, ask
    // the user to cancel it before sending a new message here.
    if (_backgroundGenerating && context.mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cancel previous generation?'),
          content: const Text(
            'A response is still being generated for a previous conversation. '
            'Cancel it to send this message?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Wait'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel and send'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        await platform.invokeMethod("cancelGeneration");
      } on PlatformException catch (e) {
        debugPrint('Platform error while cancelling background generation: $e');
      }
      await _saveAndClearBackground();
    }
    // Cancel any in-flight generation before starting a new one
    if (_isGenerating) {
      try {
        await platform.invokeMethod("cancelGeneration");
      } on PlatformException catch (e) {
        debugPrint('Platform error while cancelling previous generation: $e');
      }
      _isGenerating = false;
      if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        final last = _messages.last;
        if (last.text.isEmpty && last.retrievedDocs.isEmpty) {
          // No content at all — remove both placeholder and its user message
          _messages.removeLast();
          if (_messages.isNotEmpty && _messages.last.role == 'user') {
            _messages.removeLast();
          }
        } else {
          // Some content visible — keep the pair, mark as cancelled
          _messages[_messages.length - 1] = last.copyWith(
            isLoading: false,
            wasCancelled: true,
          );
        }
      }
    }
    final (history, historyTruncated) = _buildHistory();
    setState(() {
      _isGenerating = true;
      _messages.add(ChatMessage(role: 'user', text: prompt));
      _messages.add(ChatMessage(role: 'assistant', text: '', isLoading: true));
    });
    _textController.clear();
    _scrollToBottom();
    await _saveCurrentConversation();
    if (historyTruncated && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Older messages were removed to fit the model\'s context window.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
    }
    try {
      await platform.invokeMethod<int>("generateResponse", {
        "prompt": prompt,
        "history": history,
        "useRetrieval": _useRetrieval,
      });
    } on PlatformException catch (e) {
      debugPrint('Platform error while generating response: $e');
      if (!mounted) return;
      setState(() {
        _isGenerating = false;
        if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
          final last = _messages.last;
          if (last.text.isEmpty && last.retrievedDocs.isEmpty) {
            _messages.removeLast();
            if (_messages.isNotEmpty && _messages.last.role == 'user') {
              _messages.removeLast();
            }
          } else {
            _messages[_messages.length - 1] = last.copyWith(
              isLoading: false,
              wasCancelled: true,
            );
          }
        }
      });
    }
  }

  Future<void> _cancelGeneration() async {
    try {
      await platform.invokeMethod("cancelGeneration");
    } on PlatformException catch (e) {
      debugPrint('Platform error while cancelling: $e');
    }
    setState(() {
      _isGenerating = false;
      if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        final last = _messages.last;
        if (last.text.isEmpty && last.retrievedDocs.isEmpty) {
          // No content arrived yet — remove the empty assistant placeholder
          // and the preceding user message so the UI stays clean.
          _messages.removeLast();
          if (_messages.isNotEmpty && _messages.last.role == 'user') {
            _messages.removeLast();
          }
        } else {
          _messages[_messages.length - 1] = last.copyWith(
            isLoading: false,
            wasCancelled: true,
          );
        }
      }
    });
  }

  Future<void> _startNewConversation() async {
    await _saveCurrentConversation();
    if (_isGenerating) _setupBackgroundTracking(); // continues in background
    setState(() {
      _currentConversationId = null;
      _messages.clear();
    });
  }

  /// Saves the current conversation to disk (upsert). No-op if no user messages.
  Future<void> _saveCurrentConversation() async {
    final userMessages = _messages.where((m) => m.role == 'user').toList();
    if (userMessages.isEmpty) return;

    final id =
        _currentConversationId ??
        DateTime.now().millisecondsSinceEpoch.toString();
    _currentConversationId = id;

    final title = userMessages.first.text.length > 60
        ? '${userMessages.first.text.substring(0, 60)}…'
        : userMessages.first.text;

    // Save only completed messages (role + text). Skip loading placeholders.
    final saved = _messages
        .where((m) => m.text.isNotEmpty && !m.isLoading)
        .map((m) => {'role': m.role, 'text': m.text})
        .toList();

    await _store.save(
      Conversation(
        id: id,
        title: title,
        timestamp: DateTime.now(),
        messages: saved,
      ),
    );
  }

  /// Moves the ongoing generation to background tracking so the user can
  /// navigate away without losing the in-progress response.
  /// [_saveCurrentConversation] must have been called first so that
  /// [_currentConversationId] is already set.
  void _setupBackgroundTracking() {
    if (_currentConversationId == null) {
      return; // defensive: no content to track
    }
    _backgroundConvId = _currentConversationId;
    final firstUser = _messages.firstWhere(
      (m) => m.role == 'user',
      orElse: () => const ChatMessage(role: 'user', text: ''),
    );
    _backgroundConvTitle = firstUser.text.length > 60
        ? '${firstUser.text.substring(0, 60)}…'
        : firstUser.text;
    _backgroundMessages = _messages
        .where((m) => m.text.isNotEmpty && !m.isLoading)
        .map((m) => <String, String>{'role': m.role, 'text': m.text})
        .toList();
    // Ensure an assistant slot exists to receive further streaming tokens.
    if (_backgroundMessages.isEmpty ||
        _backgroundMessages.last['role'] != 'assistant') {
      _backgroundMessages.add(<String, String>{
        'role': 'assistant',
        'text': '',
      });
    }
    _backgroundGenerating = true;
    _isGenerating = false; // hide stop button in the new conversation view
  }

  /// Saves the background buffer to disk and clears background state.
  Future<void> _saveAndClearBackground() async {
    final id = _backgroundConvId;
    final title = _backgroundConvTitle;
    final messages = List<Map<String, String>>.from(_backgroundMessages);
    _backgroundGenerating = false;
    _backgroundConvId = null;
    _backgroundConvTitle = '';
    _backgroundMessages = [];
    if (id == null) return;
    final completed = messages.where((m) => m['text']!.isNotEmpty).toList();
    if (completed.every((m) => m['role'] != 'user')) return;
    await _store.save(
      Conversation(
        id: id,
        title: title,
        timestamp: DateTime.now(),
        messages: completed,
      ),
    );
  }

  /// Restore a past conversation and close the drawer.
  Future<void> _loadConversation(
    BuildContext drawerContext,
    Conversation conversation,
  ) async {
    if (_isGenerating) {
      await _saveCurrentConversation();
      _setupBackgroundTracking(); // continues in background
    }
    if (drawerContext.mounted) Navigator.pop(drawerContext);

    // If loading the conversation that is currently generating in background,
    // bring it back to the foreground so the response is visible again.
    if (_backgroundGenerating && _backgroundConvId == conversation.id) {
      final bgMessages = List<Map<String, String>>.from(_backgroundMessages);
      setState(() {
        _currentConversationId = conversation.id;
        _backgroundGenerating = false;
        _backgroundConvId = null;
        _backgroundConvTitle = '';
        _backgroundMessages = [];
        _isGenerating = true;
        _unreadConvIds.remove(conversation.id);
        _messages
          ..clear()
          ..addAll(
            bgMessages.map(
              (m) => ChatMessage(role: m['role']!, text: m['text']!),
            ),
          );
        // Re-attach the loading indicator to the last assistant message.
        if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
          _messages[_messages.length - 1] = _messages.last.copyWith(
            isLoading: true,
          );
        }
      });
      _scrollToBottom();
      return;
    }

    setState(() {
      _currentConversationId = conversation.id;
      _unreadConvIds.remove(conversation.id);
      _messages
        ..clear()
        ..addAll(
          conversation.messages.map(
            (m) => ChatMessage(role: m['role']!, text: m['text']!),
          ),
        );
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startListeningForLatestMessage() {
    _latestMessageSubscription = latestMessageStream
        .receiveBroadcastStream()
        .listen(
          _onLatestMessageUpdate,
          onError: (error) {
            debugPrint('Error in latestMessageStream: $error');
            if (_backgroundGenerating) _saveAndClearBackground();
            if (!mounted) return;
            setState(() {
              _isGenerating = false;
              if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
                final last = _messages.last;
                _messages[_messages.length - 1] = last.copyWith(
                  isLoading: false,
                  wasCancelled: true,
                );
              }
            });
          },
        );
  }

  /// Strips Gemma control tokens the model may include at the end of output.
  String _stripModelTokens(String text) =>
      text.trimRight().replaceAll(RegExp(r'(<end_of_turn>)+$'), '').trimRight();

  /// Update the latest assistant message as the model streams tokens.
  /// Routes events to the background buffer when the user has navigated away.
  void _onLatestMessageUpdate(dynamic value) {
    if (value is! Map) return; // guard against unexpected non-Map events
    if (!_isGenerating && !_backgroundGenerating) return; // stray event

    if (_backgroundGenerating) {
      // User navigated away — update background buffer (no setState needed).
      if (value.containsKey("done")) {
        final convId = _backgroundConvId!;
        final convTitle = _backgroundConvTitle;
        _saveAndClearBackground(); // fire-and-forget
        if (mounted) {
          setState(() => _unreadConvIds.add(convId));
          _drawerKey.currentState?.reload();
          final display = convTitle.length > 40
              ? '${convTitle.substring(0, 40)}…'
              : convTitle;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Response ready: "$display"'),
              action: SnackBarAction(
                label: 'View',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
            ),
          );
        }
        return;
      }
      if (value.containsKey("response")) {
        final text = _stripModelTokens(value["response"] as String);
        if (_backgroundMessages.isNotEmpty &&
            _backgroundMessages.last['role'] == 'assistant') {
          _backgroundMessages[_backgroundMessages.length - 1] =
              <String, String>{'role': 'assistant', 'text': text};
        }
      }
      return;
    }

    // _isGenerating == true: update the visible conversation.
    if (value.containsKey("done")) {
      setState(() => _isGenerating = false);
      _saveCurrentConversation(); // fire-and-forget
      return;
    }
    setState(() {
      final lastIdx = _messages.length - 1;
      if (lastIdx < 0 || _messages[lastIdx].role != 'assistant') return;
      if (value.containsKey("response")) {
        _messages[lastIdx] = _messages[lastIdx].copyWith(
          text: _stripModelTokens(value["response"] as String),
          isLoading: false,
        );
      } else if (value.containsKey("results")) {
        final docs = value["results"];
        if (docs is! List) return;
        _messages[lastIdx] = _messages[lastIdx].copyWith(
          retrievedDocs: docs.map<String>((a) => a as String).toList(),
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _startListeningForLatestMessage();
  }

  @override
  void dispose() {
    _latestMessageSubscription?.cancel();
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const examples = [
      "Baby continuous crying",
      "Preparing for home birth",
      "Infection risks childbirth",
      "Bleeding after delivery",
      "Newborn not breathing",
    ];

    return Scaffold(
      key: _scaffoldKey,
      onDrawerChanged: (isOpened) {
        if (isOpened) _drawerKey.currentState?.reload();
      },
      drawer: _ConversationDrawer(
        key: _drawerKey,
        store: _store,
        currentId: _currentConversationId,
        backgroundConvId: _backgroundConvId,
        unreadIds: _unreadConvIds,
        onLoad: _loadConversation,
        onNewConversation: _startNewConversation,
        onCurrentConversationDeleted: () =>
            setState(() => _currentConversationId = null),
      ),
      appBar: AppBar(
        toolbarHeight: 64,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            tooltip: 'Conversation history',
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: Colors.white,
              child: Image.asset('images/logo.png', height: 42),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'MAM-AI clinical search',
                style: TextStyle(color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        centerTitle: true,
        backgroundColor: Colors.deepOrange,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment, color: Colors.white),
            tooltip: 'New conversation',
            onPressed: _startNewConversation,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _buildSuggestionChips(examples)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      if (message.role == 'user') {
                        return _UserBubble(text: message.text);
                      } else {
                        return _AssistantCard(message: message);
                      }
                    },
                  ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildSuggestionChips(List<String> examples) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Try asking:',
              style: TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: examples
                .map(
                  (text) => SearchSuggestionChip(
                    text,
                    SuggestionType.example,
                    onPressed: _generateResponse,
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: 'Ask a medical question...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: _generateResponse,
                minLines: 1,
                maxLines: 4,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: _useRetrieval ? 'Search enabled' : 'Search disabled',
              icon: Icon(
                Icons.search,
                color: _useRetrieval ? const Color(0xffcc5500) : Colors.grey,
              ),
              onPressed: () => setState(() => _useRetrieval = !_useRetrieval),
            ),
            const SizedBox(width: 4),
            if (_isGenerating)
              IconButton.filled(
                icon: const Icon(Icons.stop),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffcc5500),
                  foregroundColor: Colors.white,
                ),
                onPressed: _cancelGeneration,
              )
            else
              IconButton.filled(
                icon: const Icon(Icons.send),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffcc5500),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _generateResponse(_textController.text),
              ),
          ],
        ),
      ),
    );
  }
}

/// We have two types of suggestion chips - example & history. Only example
/// is used so far
enum SuggestionType { example, history }

/// A search suggestion appearing in the dropdown list (kept for future use)
class SearchSuggestionTile extends StatelessWidget {
  const SearchSuggestionTile(
    this.text,
    this.type, {
    super.key,
    required this.onPressed,
  });

  final String text;
  final Function(String) onPressed;
  final SuggestionType type;

  @override
  Widget build(BuildContext context) {
    Icon icon;
    Color? textColor;

    switch (type) {
      case SuggestionType.example:
        textColor = const Color(0xff994000);
        icon = Icon(Icons.auto_awesome, color: textColor);
        break;

      case SuggestionType.history:
        icon = const Icon(Icons.history);
        break;
    }

    return ListTile(
      leading: icon,
      title: Text(text, style: TextStyle(color: textColor)),
      onTap: () => onPressed(text),
    );
  }
}

/// A search suggestion chip
class SearchSuggestionChip extends StatelessWidget {
  const SearchSuggestionChip(
    this.text,
    this.type, {
    super.key,
    required this.onPressed,
  });

  final String text;
  final Function(String) onPressed;
  final SuggestionType type;

  @override
  Widget build(BuildContext context) {
    Icon icon;
    Color? bgColor;
    Color? textColor;
    Color borderColor;

    switch (type) {
      case SuggestionType.example:
        icon = const Icon(Icons.auto_awesome);
        bgColor = Colors.orange[50];
        textColor = const Color(0xffcc5500);
        borderColor = Colors.orange[300]!;
        break;

      case SuggestionType.history:
        textColor = Colors.black.withAlpha(166);
        icon = Icon(Icons.history, color: textColor);
        bgColor = null;
        borderColor = Colors.grey;
        break;
    }

    return ChipTheme(
      data: ChipThemeData(
        labelStyle: TextStyle(color: textColor, fontWeight: FontWeight.w500),
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: borderColor),
          borderRadius: BorderRadiusGeometry.circular(12),
        ),
      ),
      child: ActionChip(
        avatar: icon,
        label: Text(text),
        onPressed: () => onPressed(text),
      ),
    );
  }
}

/// User message bubble (right-aligned, orange)
class _UserBubble extends StatelessWidget {
  final String text;
  const _UserBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 64, bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xffcc5500),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }
}

/// Assistant message card with markdown response and collapsible retrieved docs
class _AssistantCard extends StatefulWidget {
  final ChatMessage message;
  const _AssistantCard({required this.message});

  @override
  State<_AssistantCard> createState() => _AssistantCardState();
}

class _AssistantCardState extends State<_AssistantCard> {
  bool _docsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    const lightOrange = Color(0xffff7f50);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsible retrieval disclosure — shown above the response card
          if (message.retrievedDocs.isNotEmpty)
            _RetrievalDisclosure(
              docs: message.retrievedDocs,
              expanded: _docsExpanded,
              onToggle: () => setState(() => _docsExpanded = !_docsExpanded),
            ),
          // Main response card
          Card(
            elevation: 2,
            surfaceTintColor: lightOrange,
            shadowColor: lightOrange,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.isLoading)
                  _ThinkingIndicator(hasDocs: message.retrievedDocs.isNotEmpty)
                else if (message.text.isNotEmpty)
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: 16,
                      end: 24,
                      bottom: message.wasCancelled ? 8 : 16,
                    ),
                    child: SelectionContainer.disabled(
                      child: MarkdownBlock(
                        data: message.text,
                        config: MarkdownConfig(
                          configs: [
                            PConfig(textStyle: const TextStyle(fontSize: 18)),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (message.wasCancelled)
                  const Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: 16,
                      end: 24,
                      bottom: 12,
                    ),
                    child: Text(
                      'Response was interrupted.',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Disclaimer shown once generation is complete
          if (!message.isLoading && !message.wasCancelled && message.text.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4, left: 4),
              child: Text(
                'MAM-AI can make mistakes. Always verify with a senior clinician.',
                style: TextStyle(fontSize: 11, color: Colors.black38),
              ),
            ),
        ],
      ),
    );
  }
}

/// Animated "Thinking..." / "Generating response..." indicator shown while loading
class _ThinkingIndicator extends StatefulWidget {
  final bool hasDocs;
  const _ThinkingIndicator({required this.hasDocs});

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.hasDocs ? 'Generating response' : 'Thinking';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final dots = '.' * ((_controller.value * 3).floor() + 1);
          return Text(
            '$label$dots',
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 16,
              fontStyle: FontStyle.italic,
            ),
          );
        },
      ),
    );
  }
}

/// Sidebar drawer listing past conversations.
class _ConversationDrawer extends StatefulWidget {
  final ConversationStore store;
  final String? currentId;
  final String? backgroundConvId; // conversation generating in background
  final Set<String> unreadIds; // conversations with unread responses
  final Future<void> Function(BuildContext, Conversation) onLoad;
  final Future<void> Function() onNewConversation;
  final void Function() onCurrentConversationDeleted;

  const _ConversationDrawer({
    super.key,
    required this.store,
    required this.currentId,
    required this.backgroundConvId,
    required this.unreadIds,
    required this.onLoad,
    required this.onNewConversation,
    required this.onCurrentConversationDeleted,
  });

  @override
  State<_ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends State<_ConversationDrawer> {
  List<Conversation> _conversations = [];

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final conversations = await widget.store.loadAll();
    if (mounted) setState(() => _conversations = conversations);
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(dt.year, dt.month, dt.day);
    if (date == today) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return 'Today $h:$m';
    } else if (date == yesterday) {
      return 'Yesterday';
    } else {
      return '${dt.day}/${dt.month}/${dt.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Colors.deepOrange),
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Text(
                    'Past conversations',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add_comment, color: Colors.deepOrange),
            title: const Text('New conversation'),
            onTap: () {
              Navigator.pop(context);
              widget.onNewConversation();
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: _conversations.isEmpty
                ? const Center(
                    child: Text(
                      'No conversations yet',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _conversations.length,
                    itemBuilder: (context, index) {
                      final c = _conversations[index];
                      final isActive = c.id == widget.currentId;
                      final isGenerating = c.id == widget.backgroundConvId;
                      final isUnread = widget.unreadIds.contains(c.id);
                      return ListTile(
                        selected: isActive,
                        selectedTileColor: Colors.orange[50],
                        // Blue dot for unread; transparent placeholder keeps
                        // alignment consistent across all rows.
                        leading: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: isUnread ? Colors.blue : Colors.transparent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_formatTimestamp(c.timestamp)),
                        // Spinner while generating; delete button otherwise.
                        trailing: isGenerating
                            ? const SizedBox.square(
                                dimension: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.deepOrange,
                                ),
                              )
                            : IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                ),
                                color: Colors.grey,
                                tooltip: 'Delete',
                                onPressed: () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Delete conversation?'),
                                      content: Text('Delete "${c.title}"?'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text(
                                            'Delete',
                                            style: TextStyle(color: Colors.red),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed == true) {
                                    await widget.store.delete(c.id);
                                    if (c.id == widget.currentId) {
                                      widget.onCurrentConversationDeleted();
                                    }
                                    await reload();
                                  }
                                },
                              ),
                        onTap: () => widget.onLoad(context, c),
                      );
                    },
                  ),
          ),
          if (_conversations.isNotEmpty) ...[
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text(
                  'Clear all conversations',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Clear all conversations?'),
                      content: const Text(
                        'This will permanently delete all past conversations.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text(
                            'Clear all',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.store.clearAll();
                    widget.onCurrentConversationDeleted();
                    await reload();
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Collapsible section showing retrieved guideline chunks
class _RetrievalDisclosure extends StatelessWidget {
  final List<String> docs;
  final bool expanded;
  final VoidCallback onToggle;

  const _RetrievalDisclosure({
    required this.docs,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: Colors.grey,
                ),
                const SizedBox(width: 4),
                Text(
                  'Retrieved ${docs.length} guideline${docs.length == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          ...docs.map(
            (doc) => Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ListTile(
                    leading: Icon(Icons.book),
                    title: Text('Information from guidelines'),
                    contentPadding: EdgeInsetsDirectional.only(
                      start: 16,
                      end: 24,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 16,
                      end: 24,
                      bottom: 16,
                    ),
                    child: Text(doc, style: const TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
