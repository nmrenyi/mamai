import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A single saved conversation.
class Conversation {
  final String id;
  final String title;
  final DateTime timestamp;

  /// Saved messages — role + text only. No retrievedDocs, no loading state.
  final List<Map<String, String>> messages;

  const Conversation({
    required this.id,
    required this.title,
    required this.timestamp,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'messages': messages,
  };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      title: json['title'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      messages: (json['messages'] as List)
          .map((m) => Map<String, String>.from(m as Map))
          .toList(),
    );
  }
}

/// Persists conversations to a single JSON file in the app's documents directory.
class ConversationStore {
  static const _fileName = 'mam_ai_conversations.json';

  File? _file;

  Future<File> _getFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/$_fileName');
    return _file!;
  }

  /// Load all conversations, newest first.
  Future<List<Conversation>> loadAll() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return [];
      final contents = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(contents) as List;
      final conversations = jsonList
          .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
          .toList();
      conversations.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return conversations;
    } catch (e) {
      debugPrint('[ConversationStore] Error loading: $e');
      return [];
    }
  }

  /// Save (insert or update) a conversation.
  Future<void> save(Conversation conversation) async {
    try {
      final all = await loadAll();
      final idx = all.indexWhere((c) => c.id == conversation.id);
      if (idx >= 0) {
        all[idx] = conversation;
      } else {
        all.insert(0, conversation);
      }
      await _write(all);
    } catch (e) {
      debugPrint('[ConversationStore] Error saving: $e');
    }
  }

  /// Delete a conversation by id.
  Future<void> delete(String id) async {
    try {
      final all = await loadAll();
      all.removeWhere((c) => c.id == id);
      await _write(all);
    } catch (e) {
      debugPrint('[ConversationStore] Error deleting: $e');
    }
  }

  Future<void> _write(List<Conversation> conversations) async {
    final file = await _getFile();
    await file.writeAsString(
      jsonEncode(conversations.map((c) => c.toJson()).toList()),
    );
  }
}
