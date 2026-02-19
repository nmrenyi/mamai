import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';

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
    while (history.length > 1) {
      final chars = history.fold<int>(0, (sum, m) => sum + m["text"]!.length);
      if (chars <= _historyCharThreshold) break;
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
    // Cancel any in-flight generation before starting a new one
    if (_isGenerating) {
      try {
        await platform.invokeMethod("cancelGeneration");
      } on PlatformException catch (e) {
        debugPrint('Platform error while cancelling previous generation: $e');
      }
      _isGenerating = false;
      // Remove the in-progress assistant message
      if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        _messages.removeLast();
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
        _messages[_messages.length - 1] = last.copyWith(
          isLoading: false,
          wasCancelled: true,
        );
      }
    });
  }

  Future<void> _startNewConversation() async {
    if (_isGenerating) {
      try {
        await platform.invokeMethod("cancelGeneration");
      } on PlatformException catch (e) {
        debugPrint('Platform error while cancelling on new conversation: $e');
      }
    }
    setState(() {
      _isGenerating = false;
      _messages.clear();
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
          onError: (_) => setState(() => _isGenerating = false),
        );
  }

  /// Update the latest assistant message as the model streams tokens
  void _onLatestMessageUpdate(dynamic value) {
    if (value is! Map) return; // guard against unexpected non-Map events
    if (!_isGenerating) return; // ignore stray events after cancel
    if (value.containsKey("done")) {
      setState(() => _isGenerating = false);
      return;
    }
    setState(() {
      final lastIdx = _messages.length - 1;
      if (lastIdx < 0 || _messages[lastIdx].role != 'assistant') return;
      if (value.containsKey("response")) {
        _messages[lastIdx] = _messages[lastIdx].copyWith(
          text: value["response"],
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
      appBar: AppBar(
        toolbarHeight: 64,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: Colors.white,
              child: Image.asset('images/logo.png', height: 42),
            ),
            const SizedBox(width: 10),
            const Text(
              'MAM-AI clinical search',
              style: TextStyle(color: Colors.white),
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
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'MAM-AI can make mistakes. Please double-check responses.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black45),
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
