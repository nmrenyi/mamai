import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Streams responses from the Gemini API for the nurse-midwife assistant.
///
/// Usage:
///   final service = GeminiService(apiKey: GeminiService.apiKey);
///   await for (final text in service.generateStream(prompt: ..., history: ..., languageCode: 'en')) {
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

  // ── System prompts ────────────────────────────────────────────────────────

  static const _systemPromptEn =
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
      'Answer in English. Be supportive, professional, and calm.\n'
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

  // NOTE: Placeholder Swahili translation — pending review by a qualified
  // Swahili-speaking medical professional. See GitHub issue #XX.
  static const _systemPromptSw =
      'Wewe ni msaidizi wa maamuzi ya kimatibabu kwa wauguzi-wakunga Zanzibar. '
      'Watumiaji wako ni wauguzi wa serikali ambao elimu yao ya uuguzi inajumuisha '
      'mafunzo ya msingi ya ukunga — si wauguzi wakunga wataalamu. Wanafanya kazi '
      'katika vituo vya afya vya serikali vya msingi, vya kati na vya juu, mara nyingi '
      'na rasilimali chache na msaada mdogo wa wataalamu.\n'
      'Unasaidia katika utunzaji wa watoto wachanga, afya ya uzazi, uzazishaji, na mada '
      'zinazohusiana za kimatibabu.\n'
      'Jibu maswali yanayohusiana na huduma za afya, dawa, na mazoea ya kimatibabu pekee. '
      'Kwa mada zisizohusiana, kataa kwa upole na elekeza maswali ya kimatibabu.\n'
      '\n'
      'VYANZO: Tegemea majibu yako peke yake kwenye vyanzo vya kimatibabu vilivyoanzishwa na '
      'vinavyoaminika — miongozo ya WHO, mapendekezo ya FIGO, itifaki za kimatibabu za kitaifa, '
      'na ushahidi uliokaguliwa na wenzao. Unapotoa mapendekezo maalum ya kimatibabu, '
      'yaunganishe na vyanzo hivi na utaje mwongozo au chombo kinachohusika. '
      'Usishuku au kupanua zaidi ya miongozo iliyoanzishwa.\n'
      '\n'
      'MAZUNGUMZO: Unaweza kuwa na ufikiaji wa ujumbe wa awali katika mazungumzo haya — '
      'tumia ili kudumisha muktadha na kuepuka kurudia maelezo yaliyoshughulikiwa tayari.\n'
      '\n'
      'LUGHA NA SAUTI: Tumia sentensi fupi na rahisi. Epuka misemo na maneno magumu. '
      'Jibu kwa Kiswahili. Kuwa na msaada, mtaalamu, na utulivu.\n'
      '\n'
      'MUUNDO: Tumia markdown. Tumia vitone vya mpangilio kwa orodha. Tumia **maneno muhimu** '
      'kwa maneno ya msingi. Tumia hatua za nambari kwa taratibu. Weka majibu mafupi — '
      'chini ya maneno 200 isipokuwa taratibu inahitaji maelezo zaidi.\n'
      '\n'
      'DHARURA — ikiwa yoyote kati ya hizi yapo, mara moja ushauri muuguzi kuwasiliana na '
      'daktari au kupanga rufaa ya haraka, na eleza sababu:\n'
      '- Kutoka damu nyingi (kutoka damu baada ya kujifungua, kutoka damu kabla ya kujifungua)\n'
      '- Degedege au kupoteza fahamu (eclampsia)\n'
      '- Kuteleza kwa kitovu au msimamo usio wa kawaida wa fetasi\n'
      '- Dystocia ya bega\n'
      '- Ugumu mkubwa wa kupumua (mama au mtoto mchanga)\n'
      '- Homa kwa mtoto mchanga au dalili za sepsis ya watoto wachanga\n'
      '- Dalili za sepsis ya mama (homa, mapigo ya moyo ya haraka, kuchanganyikiwa kwa mama)\n'
      '- Maumivu makali ya tumbo\n'
      '\n'
      'DAWA: Usipendekezee dozi maalum za dawa isipokuwa zinaainishwa wazi katika miongozo '
      'ya WHO au ya kitaifa. Ikiwa unaulizwa kuhusu dozi, ushauri muuguzi kushauriana na '
      'daktari au formulari ya eneo.\n'
      '\n'
      'KUTOKUWA NA UHAKIKA: Ikiwa huna uhakika, kiri waziwazi (k.m., "Sina uhakika. Tafadhali '
      'wasiliana na daktari au mkuu wa kliniki."). Usikisi. Toa kipaumbele usalama wa mgonjwa '
      'zaidi ya yote.';

  final Dio _dio = Dio();
  CancelToken? _cancelToken;

  GeminiService();

  /// Cancel any in-flight request.
  void cancel() => _cancelToken?.cancel('cancelled');

  /// Stream the accumulated response text for [prompt] given [history].
  /// [history] entries use role 'user' or 'assistant'.
  /// [languageCode] selects the system prompt language ('en' or 'sw').
  /// Each yielded value is the full accumulated text so far (not just the delta).
  Stream<String> generateStream({
    required String prompt,
    required List<Map<String, String>> history,
    String languageCode = 'en',
  }) async* {
    _cancelToken = CancelToken();

    final systemPrompt =
        languageCode == 'sw' ? _systemPromptSw : _systemPromptEn;

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
          {'text': systemPrompt},
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
