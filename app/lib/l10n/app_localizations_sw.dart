// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Swahili (`sw`).
class AppLocalizationsSw extends AppLocalizations {
  AppLocalizationsSw([String locale = 'sw']) : super(locale);

  @override
  String get appBarSubtitle => 'Kwa wauguzi wakunga Zanzibar';

  @override
  String get tooltipConversationHistory => 'Historia ya mazungumzo';

  @override
  String get tooltipNewConversation => 'Mazungumzo mapya';

  @override
  String get tooltipCloudAI =>
      'AI ya wingu (gonga kubadilisha hadi kwenye kifaa)';

  @override
  String get tooltipOnDevice => 'Kwenye kifaa (gonga kubadilisha hadi winguni)';

  @override
  String get tooltipSearchEnabled => 'Utafutaji umewashwa';

  @override
  String get tooltipSearchDisabled => 'Utafutaji umezimwa';

  @override
  String get searchOn => 'Tafuta IMEWASHWA';

  @override
  String get searchOff => 'Tafuta IMEZIMWA';

  @override
  String get dialogCancelGenerationTitle => 'Ghairi uzalishaji uliopita?';

  @override
  String get dialogCancelGenerationContent =>
      'Jibu bado linazalishwa kwa mazungumzo ya awali. Lighairie kutuma ujumbe huu?';

  @override
  String get dialogWait => 'Ngoja';

  @override
  String get dialogCancelAndSend => 'Ghairi na tuma';

  @override
  String get snackbarHistoryTruncated =>
      'Ujumbe wa zamani uliondolewa ili kulingana na dirisha la muktadha la modeli.';

  @override
  String snackbarResponseReady(String title) {
    return 'Jibu liko tayari: \"$title\"';
  }

  @override
  String get snackbarView => 'Tazama';

  @override
  String get emptyStateHeading => 'Unahitaji msaada gani leo?';

  @override
  String get emptyStateSubheading => 'Hapa kukusaidia mahali pa huduma.';

  @override
  String get exampleChip1 => 'Ninapimaje urefu wa fundal?';

  @override
  String get exampleChip2 =>
      'Mtoto mchanga wa mgonjwa wangu hawezi kunyonya, nifanye nini?';

  @override
  String get exampleChip3 => 'Ninatunzaje kitovu baada ya kuzaa?';

  @override
  String get exampleChip4 =>
      'Ninapaswa kutoa dawa za chuma lini wakati wa ujauzito?';

  @override
  String get exampleChip5 =>
      'Kupungua kwa uzito wa mtoto mchanga kiasi gani ni kawaida?';

  @override
  String get inputHint => 'Eleza hali yako ya kliniki...';

  @override
  String get disclaimer =>
      'Daima tumia uamuzi wako wa kimatibabu. Kwa dharura, piga kengele haraka.';

  @override
  String get thinkingLabel => 'Nafikiri';

  @override
  String get generatingLabel => 'Ninatengeneza jibu';

  @override
  String get responseCancelled => 'Jibu lilikatizwa.';

  @override
  String get aboutTitle => 'Kuhusu';

  @override
  String get aboutDescription =>
      'Chombo cha msaada wa maamuzi ya kimatibabu kwa wauguzi-wakunga Zanzibar. Kinatoa majibu kamili bila mtandao, yanayolingana na miongozo ya kimatibabu — inayoshughulikia afya ya uzazi, uzazishaji, na utunzaji wa watoto wachanga — kwa msaada wa kuaminika, wa siri mahali pa huduma.';

  @override
  String get aboutKnowledgeBundleTitle => 'Kifurushi cha maarifa';

  @override
  String get aboutKnowledgeBundleUnavailable =>
      'Taarifa za kifurushi bado hazipatikani kwenye kifaa hiki.';

  @override
  String get aboutKnowledgeBundleVersionLabel => 'Toleo';

  @override
  String get aboutKnowledgeBundleDeployedLabel => 'Kimepelekwa';

  @override
  String get drawerAbout => 'Kuhusu MAM-AI';

  @override
  String get drawerTitle => 'Mazungumzo ya zamani';

  @override
  String get drawerNewConversation => 'Mazungumzo mapya';

  @override
  String get drawerNoConversations => 'Hakuna mazungumzo bado';

  @override
  String timestampToday(String time) {
    return 'Leo $time';
  }

  @override
  String get timestampYesterday => 'Jana';

  @override
  String get deleteConversationTitle => 'Futa mazungumzo?';

  @override
  String deleteConversationContent(String title) {
    return 'Futa \"$title\"?';
  }

  @override
  String get dialogCancel => 'Ghairi';

  @override
  String get dialogDelete => 'Futa';

  @override
  String get clearAllTitle => 'Futa mazungumzo yote?';

  @override
  String get clearAllContent => 'Hii itafuta kabisa mazungumzo yote ya zamani.';

  @override
  String get clearAllButton => 'Futa yote';

  @override
  String get clearAllDrawerItem => 'Futa mazungumzo yote';

  @override
  String retrievedGuidelines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Miongozo $count iliyopatikana',
      one: 'Mwongozo 1 uliopatikana',
    );
    return '$_temp0';
  }

  @override
  String get introCheckingLLM => 'Inaangalia kama LLM imewekwa...';

  @override
  String get introLLMLoading =>
      'LLM inawashwa (inaweza kuchukua muda mara ya kwanza)...';

  @override
  String get introStartChat => 'Anza mazungumzo';

  @override
  String get introDownloadModels => 'Pakua mifano';

  @override
  String introDownloadingModels(String percent) {
    return 'Inapakua mifano ($percent%)';
  }

  @override
  String get introWelcome => 'Karibu MAM-AI';

  @override
  String get introDescription =>
      'Majibu ya kuaminika ya kimatibabu, bila mtandao, daima tayari.';

  @override
  String get introPartnership => 'Kwa ushirikiano na';

  @override
  String get licenseTitle => 'Kubali leseni ya Gemma3n';

  @override
  String get licenseIntro =>
      'Tafadhali soma na kukubali leseni ya Gemma3n na sera ya matumizi yaliyokatazwa.';

  @override
  String get licenseTermsText =>
      'Gemma inatolewa chini ya na kulingana na Masharti ya Matumizi ya Gemma yanayopatikana katika';

  @override
  String get licenseUsagePolicyLink => 'Sera ya matumizi ya Gemma3n';

  @override
  String get licenseAccept => 'Kubali';

  @override
  String get licenseDeny => 'Kataa';

  @override
  String get switchToSwahili => 'Kiswahili';

  @override
  String get switchToEnglish => 'Kiingereza';

  @override
  String get errorOnDeviceUnavailable =>
      'Hali ya kwenye kifaa haipatikani hapa. Badilisha kwenda AI ya wingu kutuma ujumbe.';

  @override
  String get switchToCloudAIAction => 'Tumia AI ya wingu';

  @override
  String get errorNoApiKey =>
      'Hakuna ufunguo wa API uliosanidiwa. Jenga tena na --dart-define=GEMINI_API_KEY=ufunguo_wako kutumia AI ya wingu.';

  @override
  String errorApiKeyInvalid(int code) {
    return 'Ufunguo wa API ni batili au haujaidhinishwa (HTTP $code). Angalia GEMINI_API_KEY yako.';
  }

  @override
  String get errorRateLimited =>
      'Maombi mengi sana — tafadhali subiri kidogo kisha jaribu tena.';

  @override
  String get errorNoInternet =>
      'Haiwezekani kufikia AI ya wingu. Angalia muunganisho wako wa mtandao.';

  @override
  String errorCloudUnavailable(int code) {
    return 'AI ya wingu ilirejesha hitilafu (HTTP $code). Tafadhali jaribu tena.';
  }
}
