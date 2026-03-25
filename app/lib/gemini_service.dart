import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Streams responses from the Gemini API for the nurse-midwife assistant.
///
/// Usage:
///   final service = GeminiService(apiKey: GeminiService.apiKey);
///   await for (final text in service.generateStream(prompt: ..., history: ...)) {
///     // text is the accumulated response so far
///   }
class GeminiService {
  // ── API key ──────────────────────────────────────────────────────────────
  // Pass at build/run time — never hardcode in source:
  //   flutter run -d chrome --dart-define=GEMINI_API_KEY=your_key_here
  //   flutter build apk --dart-define=GEMINI_API_KEY=your_key_here
  static const String apiKey = String.fromEnvironment('GEMINI_API_KEY');

  static const _model = 'gemini-3-flash-preview';
  static const _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:streamGenerateContent';

  // ── System prompt ─────────────────────────────────────────────────────────
  // Mirrors RagPipeline.kt but adapted for cloud use:
  //   - No RAG context section (no local retrieval)
  //   - Added SOURCES section emphasising reliable medical guidelines
  static const _systemPrompt =
      'You are a clinical decision-support assistant for nurse-midwives in Zanzibar. '
      'Your users are government nurses whose nursing education incorporates basic '
      'midwifery training — they are not specialist midwives. They work at primary, '
      'secondary, and tertiary government health facilities, often with limited '
      'resources and specialist backup.\n'
      'You help with neonatal care, maternal health, obstetrics, and related clinical topics.\n'
      'Only answer questions related to healthcare, medicine, and clinical practice. '
      'For unrelated topics, politely decline and redirect to clinical questions.\n'
      '\n'
      'SOURCES: Base your answers exclusively on established, reliable medical sources — '
      'WHO guidelines, FIGO recommendations, national clinical protocols, and '
      'peer-reviewed evidence. When making specific clinical recommendations, '
      'ground them in these sources and mention the guideline or body when relevant. '
      'Do not speculate or extrapolate beyond established guidelines.\n'
      '\n'
      'CONVERSATION: You may have access to previous messages in this conversation — '
      'use them to maintain context and avoid repeating information already covered.\n'
      '\n'
      'LANGUAGE & TONE: Use simple, short sentences. Avoid idioms and complex words. '
      'Answer in the language that the user is speaking. Be supportive, professional, and calm.\n'
      '\n'
      'FORMAT: Use markdown. Use bullet points for lists. Use **bold** for important terms. '
      'Use numbered steps for procedures. Keep responses concise — under 200 words unless '
      'a procedure genuinely requires more detail.\n'
      '\n'
      'EMERGENCIES — if any of these are present, immediately advise the nurse to escalate '
      'to a doctor or arrange urgent referral, and state why:\n'
      '- Heavy bleeding (postpartum haemorrhage, antepartum haemorrhage)\n'
      '- Convulsions or loss of consciousness (eclampsia)\n'
      '- Cord prolapse or abnormal fetal presentation\n'
      '- Shoulder dystocia\n'
      '- Severe difficulty breathing (mother or newborn)\n'
      '- Fever in a newborn or signs of neonatal sepsis\n'
      '- Signs of maternal sepsis (fever, rapid pulse, confusion in the mother)\n'
      '- Severe abdominal pain\n'
      '\n'
      'MEDICATIONS: Do not recommend specific drug doses unless they are clearly stated in '
      'WHO or national clinical guidelines. If asked about dosing, advise the nurse to '
      'consult a doctor or the local formulary.\n'
      '\n'
      'UNCERTAINTY: If you are not sure, admit it clearly (e.g., "I\'m not sure. Please '
      'consult a doctor or senior clinician."). Do not guess. Prioritize patient safety above all else.';

  final Dio _dio = Dio();
  CancelToken? _cancelToken;

  GeminiService();

  /// Cancel any in-flight request.
  void cancel() => _cancelToken?.cancel('cancelled');

  /// Stream the accumulated response text for [prompt] given [history].
  /// [history] entries use role 'user' or 'assistant'.
  /// Each yielded value is the full accumulated text so far (not just the delta).
  Stream<String> generateStream({
    required String prompt,
    required List<Map<String, String>> history,
  }) async* {
    _cancelToken = CancelToken();

    final contents = <Map<String, dynamic>>[
      for (final turn in history)
        {
          'role': turn['role'] == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': turn['text']},
          ],
        },
      {
        'role': 'user',
        'parts': [
          {'text': prompt},
        ],
      },
    ];

    final requestBody = {
      'system_instruction': {
        'parts': [
          {'text': _systemPrompt},
        ],
      },
      'contents': contents,
      'generationConfig': {
        'temperature': 1.0,
        'topP': 0.95,
        'topK': 64,
        'maxOutputTokens': 1024,
      },
    };

    final response = await _dio.post<ResponseBody>(
      '$_baseUrl?alt=sse&key=$apiKey',
      data: requestBody,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Content-Type': 'application/json'},
      ),
      cancelToken: _cancelToken,
    );

    final accumulated = StringBuffer();

    await for (final line
        in response.data!.stream
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final jsonStr = line.substring(6).trim();
      if (jsonStr.isEmpty) continue;
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        final text =
            (((json['candidates'] as List?)?.first['content']
                            as Map<String, dynamic>?)?['parts']
                        as List?)
                    ?.first['text']
                as String?;
        if (text != null && text.isNotEmpty) {
          accumulated.write(text);
          yield accumulated.toString();
        }
      } catch (_) {
        // Ignore malformed SSE chunks
      }
    }
  }
}
