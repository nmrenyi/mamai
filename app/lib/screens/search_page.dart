import 'dart:async';
import 'dart:io';
import 'package:app/locale_notifier.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app/l10n/app_localizations.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../conversation_store.dart';
import '../gemini_service.dart';

/// A retrieved guideline chunk with source metadata.
class RetrievedDoc {
  final String text;   // chunk body
  final String source; // filename stem, e.g. "WHO_PositiveBirth_2018"
  final int page;      // PDF page number (0 = unknown / legacy chunk)

  const RetrievedDoc({
    required this.text,
    this.source = '',
    this.page = 0,
  });

  bool get hasSource => source.isNotEmpty && page > 0;

  /// Human-readable label, e.g. "WHO Positive Birth 2018 · p.42"
  String get label {
    final name = source.replaceAll('_', ' ');
    return hasSource ? '$name · p.$page' : name.isNotEmpty ? name : 'Guideline';
  }

  static RetrievedDoc fromMap(dynamic raw) {
    if (raw is Map) {
      return RetrievedDoc(
        text: raw['text'] as String? ?? '',
        source: raw['source'] as String? ?? '',
        page: (raw['page'] as num?)?.toInt() ?? 0,
      );
    }
    // Legacy: plain string (old embeddings.sqlite without metadata prefix)
    return RetrievedDoc(text: raw as String? ?? '');
  }
}

/// A single message in the conversation
class ChatMessage {
  final String role; // "user" or "assistant"
  final String text;
  final List<RetrievedDoc> retrievedDocs;
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
    List<RetrievedDoc>? retrievedDocs,
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
  bool _useCloudLLM = false;
  GeminiService? _geminiService;
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
      16000; // system prompt (~1800) + 3 retrieved docs (~6000) + query + response headroom
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
      final l10n = AppLocalizations.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.dialogCancelGenerationTitle),
          content: Text(l10n.dialogCancelGenerationContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.dialogWait),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.dialogCancelAndSend),
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
    FocusManager.instance.primaryFocus?.unfocus();
    _scrollToBottom();
    await _saveCurrentConversation();
    if (historyTruncated && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).snackbarHistoryTruncated),
          duration: Duration(seconds: 4),
        ),
      );
    }
    if (_useCloudLLM) {
      await _generateWithGemini(prompt, history);
    } else {
      try {
        await platform.invokeMethod<int>("generateResponse", {
          "prompt": prompt,
          "history": history,
          "useRetrieval": _useRetrieval,
          "language": appLocale.value.languageCode,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.message}')),
        );
      } catch (e) {
        // MissingPluginException on non-Android platforms — on-device mode
        // is not available. Keep the user message visible, show a SnackBar
        // with a one-tap action to switch to Cloud AI.
        debugPrint('Channel unavailable: $e');
        if (!mounted) return;
        final l10n = AppLocalizations.of(context);
        setState(() {
          _isGenerating = false;
          // Remove assistant placeholder then user message — both were just
          // added in _sendMessage. Restore prompt to the input field so the
          // user can re-send or edit after dismissing the dialog.
          if (_messages.isNotEmpty &&
              _messages.last.role == 'assistant' &&
              _messages.last.text.isEmpty &&
              _messages.last.retrievedDocs.isEmpty) {
            _messages.removeLast();
          }
          if (_messages.isNotEmpty && _messages.last.role == 'user') {
            _messages.removeLast();
          }
          _textController.text = prompt;
        });
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text(l10n.errorOnDeviceUnavailable),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l10n.dialogCancel),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  if (!mounted) return;
                  setState(() {
                    _useCloudLLM = true;
                    _isGenerating = true;
                    _messages.add(ChatMessage(role: 'user', text: prompt));
                    _messages.add(
                      ChatMessage(
                        role: 'assistant',
                        text: '',
                        isLoading: true,
                      ),
                    );
                    _textController.clear();
                  });
                  _scrollToBottom();
                  _generateWithGemini(prompt, history);
                },
                child: Text(l10n.switchToCloudAIAction),
              ),
            ],
          ),
        );
      }
    }
  }

  /// Generate a response via the Gemini cloud API, streaming tokens into the UI.
  Future<void> _generateWithGemini(
    String prompt,
    List<Map<String, String>> history,
  ) async {
    // Guard: API key missing — show a clear error instead of a cryptic 403.
    if (GeminiService.apiKey.isEmpty) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _isGenerating = false;
        if (_messages.isNotEmpty && _messages.last.role == 'assistant' &&
            _messages.last.text.isEmpty && _messages.last.retrievedDocs.isEmpty) {
          _messages.removeLast();
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.errorNoApiKey),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }
    _geminiService = GeminiService();
    var completed = false;
    String? apiError;
    try {
      await for (final text in _geminiService!.generateStream(
        prompt: prompt,
        history: history,
        languageCode: appLocale.value.languageCode,
      )) {
        if (!mounted) return;
        setState(() {
          final lastIdx = _messages.length - 1;
          if (lastIdx >= 0 && _messages[lastIdx].role == 'assistant') {
            _messages[lastIdx] = _messages[lastIdx].copyWith(
              text: text,
              isLoading: false,
            );
          }
        });
        _scrollToBottom();
      }
      completed = true;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        completed = true; // cancellation is intentional — not an error
      } else {
        debugPrint('Gemini API error: $e');
        if (!mounted) return;
        final l10n = AppLocalizations.of(context);
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) {
          apiError = l10n.errorApiKeyInvalid(status!);
        } else if (status == 429) {
          apiError = l10n.errorRateLimited;
        } else if (e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.unknown) {
          apiError = l10n.errorNoInternet;
        } else {
          apiError = l10n.errorCloudUnavailable(status ?? 0);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          if (!completed &&
              _messages.isNotEmpty &&
              _messages.last.role == 'assistant') {
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
        await _saveCurrentConversation();
      }
    }
    if (apiError != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(apiError),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  Future<void> _cancelGeneration() async {
    if (_useCloudLLM) {
      // Cloud path: cancel the Dio request. Message cleanup is handled by
      // _generateWithGemini's finally block once the stream throws.
      _geminiService?.cancel();
      return;
    }
    // On-device path
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

  /// Cancels any in-flight generation, deletes all saved conversations, and
  /// resets the chat to a blank state. Called from the drawer's "Clear all".
  Future<void> _onClearAll() async {
    if (_isGenerating || _backgroundGenerating) {
      try {
        await platform.invokeMethod("cancelGeneration");
      } on PlatformException catch (e) {
        debugPrint('Platform error while cancelling for clear-all: $e');
      }
    }
    await _store.clearAll();
    if (!mounted) return;
    setState(() {
      _isGenerating = false;
      _backgroundGenerating = false;
      _backgroundConvId = null;
      _backgroundConvTitle = '';
      _backgroundMessages = [];
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
          final l10n = AppLocalizations.of(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.snackbarResponseReady(display)),
              action: SnackBarAction(
                label: l10n.snackbarView,
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
          retrievedDocs: docs.map<RetrievedDoc>(RetrievedDoc.fromMap).toList(),
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // EventChannel is Android-only — skip on web/desktop to avoid
    // MissingPluginException during UI development without a device.
    if (!kIsWeb && Platform.isAndroid) {
      _startListeningForLatestMessage();
    }
  }

  @override
  void dispose() {
    _latestMessageSubscription?.cancel();
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _toggleLocale() async {
    final newLocale = appLocale.value.languageCode == 'en'
        ? const Locale('sw')
        : const Locale('en');
    appLocale.value = newLocale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', newLocale.languageCode);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final examples = [
      (l10n.exampleChip1, Icons.pregnant_woman),
      (l10n.exampleChip2, Icons.child_care),
      (l10n.exampleChip3, Icons.healing),
      (l10n.exampleChip4, Icons.medication),
      (l10n.exampleChip5, Icons.monitor_weight),
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
        isGenerating: _isGenerating,
        onLoad: _loadConversation,
        onNewConversation: _startNewConversation,
        onCurrentConversationDeleted: () =>
            setState(() => _currentConversationId = null),
        onClearAll: _onClearAll,
      ),
      appBar: AppBar(
        toolbarHeight: 64,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            tooltip: l10n.tooltipConversationHistory,
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
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'MAM-AI',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    l10n.appBarSubtitle,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: Color(0xffDE7356),
        actions: [
          // Language toggle: shows current language code in a rounded badge
          ValueListenableBuilder<Locale>(
            valueListenable: appLocale,
            builder: (_, locale, __) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: GestureDetector(
                onTap: _toggleLocale,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    locale.languageCode.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_comment, color: Colors.white),
            tooltip: l10n.tooltipNewConversation,
            onPressed: _startNewConversation,
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? _buildSuggestionChips(examples, l10n)
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        if (message.role == 'user') {
                          return _UserBubble(text: message.text);
                        } else {
                          final isLastMessage = index == _messages.length - 1;
                          return _AssistantCard(
                            message: message,
                            showDisclaimer: isLastMessage && !_isGenerating,
                          );
                        }
                      },
                    ),
            ),
            _buildInputBar(l10n),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionChips(
    List<(String, IconData)> examples,
    AppLocalizations l10n,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l10n.emptyStateHeading,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              l10n.emptyStateSubheading,
              style: const TextStyle(fontSize: 14, color: Colors.black45),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: examples
                .map(
                  (e) => SearchSuggestionChip(
                    e.$1,
                    SuggestionType.example,
                    chipIcon: e.$2,
                    onPressed: _generateResponse,
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(AppLocalizations l10n) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: l10n.inputHint,
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
            // Cloud / on-device toggle
            Tooltip(
              message: _useCloudLLM
                  ? l10n.tooltipCloudAI
                  : l10n.tooltipOnDevice,
              child: IconButton(
                icon: Icon(
                  _useCloudLLM ? Icons.cloud : Icons.smartphone,
                  color: _useCloudLLM ? Colors.blue[700] : Colors.grey[500],
                ),
                onPressed: () {
                  setState(() => _useCloudLLM = !_useCloudLLM);
                  // _useCloudLLM is already the NEW value after setState
                  if (_useCloudLLM && GeminiService.apiKey.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.errorNoApiKey),
                        duration: const Duration(seconds: 8),
                      ),
                    );
                  }
                },
              ),
            ),
            // Search toggle — only relevant for on-device mode on Android
            if (!_useCloudLLM && !kIsWeb && Platform.isAndroid) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => setState(() => _useRetrieval = !_useRetrieval),
                child: Tooltip(
                  message: _useRetrieval
                      ? l10n.tooltipSearchEnabled
                      : l10n.tooltipSearchDisabled,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _useRetrieval
                          ? Color(0xffDE7356)
                          : Colors.grey[400],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _useRetrieval ? l10n.searchOn : l10n.searchOff,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            if (_isGenerating)
              IconButton.filled(
                icon: const Icon(Icons.stop),
                style: IconButton.styleFrom(
                  backgroundColor: Color(0xffDE7356),
                  foregroundColor: Colors.white,
                ),
                onPressed: _cancelGeneration,
              )
            else
              IconButton.filled(
                icon: const Icon(Icons.send),
                style: IconButton.styleFrom(
                  backgroundColor: Color(0xffDE7356),
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
        textColor = const Color(0xffB85C42);
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
    this.chipIcon,
  });

  final String text;
  final Function(String) onPressed;
  final SuggestionType type;
  final IconData? chipIcon;

  @override
  Widget build(BuildContext context) {
    Color? bgColor;
    Color? textColor;
    Color borderColor;

    switch (type) {
      case SuggestionType.example:
        bgColor = Color(0xffF4F3EE);
        textColor = Color(0xffDE7356);
        borderColor = Color(0xffE8E6DC);
        break;

      case SuggestionType.history:
        textColor = Colors.black.withAlpha(166);
        bgColor = null;
        borderColor = Colors.grey;
        break;
    }

    final resolvedIcon = chipIcon ??
        (type == SuggestionType.history ? Icons.history : Icons.auto_awesome);

    return ChipTheme(
      data: ChipThemeData(
        labelStyle: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w500,
          fontSize: 14,
        ),
        backgroundColor: bgColor,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: borderColor),
          borderRadius: BorderRadiusGeometry.circular(12),
        ),
      ),
      child: ActionChip(
        avatar: Icon(resolvedIcon, color: textColor),
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
          color: Color(0xffDE7356),
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
  final bool showDisclaimer;
  const _AssistantCard({required this.message, this.showDisclaimer = false});

  @override
  State<_AssistantCard> createState() => _AssistantCardState();
}

class _AssistantCardState extends State<_AssistantCard> {
  bool _docsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final l10n = AppLocalizations.of(context);
    const lightOrange = Color(0xffDE7356);

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
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 16,
                      end: 24,
                      bottom: 12,
                    ),
                    child: Text(
                      l10n.responseCancelled,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Disclaimer shown on the latest response once generation is complete
          if (widget.showDisclaimer)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                l10n.disclaimer,
                style: const TextStyle(fontSize: 11, color: Colors.black38),
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
    final l10n = AppLocalizations.of(context);
    final label = widget.hasDocs ? l10n.generatingLabel : l10n.thinkingLabel;
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
  final bool isGenerating; // foreground generation in progress
  final Future<void> Function(BuildContext, Conversation) onLoad;
  final Future<void> Function() onNewConversation;
  final void Function() onCurrentConversationDeleted;
  final Future<void> Function() onClearAll;

  const _ConversationDrawer({
    super.key,
    required this.store,
    required this.currentId,
    required this.backgroundConvId,
    required this.unreadIds,
    required this.isGenerating,
    required this.onLoad,
    required this.onNewConversation,
    required this.onCurrentConversationDeleted,
    required this.onClearAll,
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

  String _formatTimestamp(DateTime dt, AppLocalizations l10n) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(dt.year, dt.month, dt.day);
    if (date == today) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return l10n.timestampToday('$h:$m');
    } else if (date == yesterday) {
      return l10n.timestampYesterday;
    } else {
      return '${dt.day}/${dt.month}/${dt.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Color(0xffDE7356)),
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    l10n.drawerTitle,
                    style: const TextStyle(
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
            leading: const Icon(Icons.add_comment, color: Color(0xffDE7356)),
            title: Text(l10n.drawerNewConversation),
            onTap: () {
              Navigator.pop(context);
              widget.onNewConversation();
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: _conversations.isEmpty
                ? Center(
                    child: Text(
                      l10n.drawerNoConversations,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _conversations.length,
                    itemBuilder: (context, index) {
                      final c = _conversations[index];
                      final isActive = c.id == widget.currentId;
                      final isBackgroundGenerating =
                          c.id == widget.backgroundConvId;
                      final isForegroundGenerating =
                          isActive && widget.isGenerating;
                      final isUnread = widget.unreadIds.contains(c.id);
                      return ListTile(
                        selected: isActive,
                        selectedTileColor: Color(0xffF4F3EE),
                        // Blue dot for unread; transparent placeholder keeps
                        // alignment consistent across all rows.
                        leading: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: isUnread
                                ? Colors.blue
                                : Colors.transparent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_formatTimestamp(c.timestamp, l10n)),
                        // Spinner for background generation; nothing for
                        // foreground generation; delete button otherwise.
                        trailing: isBackgroundGenerating
                            ? const SizedBox.square(
                                dimension: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xffDE7356),
                                ),
                              )
                            : isForegroundGenerating
                            ? const SizedBox.shrink()
                            : IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                ),
                                color: Colors.grey,
                                tooltip: l10n.dialogDelete,
                                onPressed: () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text(l10n.deleteConversationTitle),
                                      content: Text(
                                        l10n.deleteConversationContent(c.title),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: Text(l10n.dialogCancel),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: Text(
                                            l10n.dialogDelete,
                                            style: const TextStyle(
                                              color: Colors.red,
                                            ),
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
                title: Text(
                  l10n.clearAllDrawerItem,
                  style: const TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(l10n.clearAllTitle),
                      content: Text(l10n.clearAllContent),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(l10n.dialogCancel),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(
                            l10n.clearAllButton,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.onClearAll();
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
  final List<RetrievedDoc> docs;
  final bool expanded;
  final VoidCallback onToggle;

  static const _platform = MethodChannel(
    "io.github.mzsfighters.mam_ai/request_generation",
  );

  const _RetrievalDisclosure({
    required this.docs,
    required this.expanded,
    required this.onToggle,
  });

  Future<void> _openPdf(BuildContext context, RetrievedDoc doc) async {
    if (!doc.hasSource) return;
    try {
      final opened = await _platform.invokeMethod<bool>(
        'openPdf',
        {'source': doc.source, 'page': doc.page},
      );
      if (opened != true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open PDF. No PDF viewer installed on this device.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } on PlatformException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open PDF: ${e.message}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                  l10n.retrievedGuidelines(docs.length),
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          ...docs.map(
            (doc) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: const Color(0xffF4F3EE),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xffE8E6DC)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Source chip — tappable if we have metadata
                  if (doc.hasSource)
                    InkWell(
                      onTap: () => _openPdf(context, doc),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(8),
                      ),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: const BoxDecoration(
                          color: Color(0xffE8E6DC),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(7),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 14,
                              color: Color(0xff8B6914),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                doc.label,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xff8B6914),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(
                              Icons.open_in_new,
                              size: 12,
                              color: Color(0xff8B6914),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // Chunk text
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      doc.text,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
