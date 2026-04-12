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
  String get introDownloadIncludesTitle => 'Usanidi huu utapakua';

  @override
  String get introDownloadSpeedLabel => 'Kasi';

  @override
  String introDownloadFinishesIn(String time) {
    return 'inakamilika baada ya $time';
  }

  @override
  String get introDownloadStatusQueued => 'Imepangwa';

  @override
  String get introDownloadStatusStarting => 'Inaanza';

  @override
  String get introDownloadStatusReady => 'Tayari';

  @override
  String get introDownloadStatusFinalizing => 'Inafungua kifurushi';

  @override
  String get introDownloadStatusDecompressing => 'Inafungua data';

  @override
  String get introDownloadStatusScanning => 'Inasoma faili';

  @override
  String get introDownloadStatusExtracting => 'Inasanikisha maktaba ya maarifa';

  @override
  String get introDownloadStatusVerifying => 'Inathibitisha';

  @override
  String introDownloadBundleDecompressing(String current, String total) {
    return 'Inafungua kumbukumbu ya kifurushi: $current kati ya $total.';
  }

  @override
  String get introDownloadBundleScanning =>
      'Inasoma yaliyomo kwenye kifurushi ili programu iandae faili za bila mtandao.';

  @override
  String introDownloadBundleExtracting(
    String current,
    String total,
    int count,
  ) {
    return 'Inasanikisha maktaba ya maarifa ya matibabu ($current kati ya $total): inahifadhi faharasa ya utafutaji na PDF $count za miongozo ya kliniki kwenye kifaa chako ili programu iweze kujibu maswali bila mtandao.';
  }

  @override
  String introDownloadBundleVerifying(int count) {
    return 'Inakagua kuwa hifadhidata ya ulinganishi na PDF $count za miongozo ziko tayari.';
  }

  @override
  String introDownloadBundleParallel(int count) {
    return 'Kifurushi cha maarifa tayari kimepakuliwa. Programu sasa inafungua hifadhidata ya ulinganishi na PDF $count za miongozo huku faili za modeli zilizobaki zikiendelea kupakuliwa.';
  }

  @override
  String introDownloadBundleOnly(int count) {
    return 'Vipakuzi vyote vimekamilika. Programu sasa inafungua hifadhidata ya ulinganishi na PDF $count za miongozo, kisha inathibitisha data za bila mtandao.';
  }

  @override
  String get introAssetGemmaTitle => 'Mfano wa Gemma 4 kwenye kifaa';

  @override
  String get introAssetGemmaSubtitle =>
      'Mfano mkuu wa lugha kwa majibu ya mazungumzo.';

  @override
  String get introAssetGeckoTitle => 'Mfano wa Gecko wa ulinganishi';

  @override
  String get introAssetGeckoSubtitle =>
      'Hutumika kupata sehemu za mwongozo zinazofaa zaidi.';

  @override
  String get introAssetTokenizerTitle => 'Tokenizer ya SentencePiece';

  @override
  String get introAssetTokenizerSubtitle =>
      'Tokenizer inayohitajika na mfano wa ulinganishi.';

  @override
  String get introAssetBundleTitle => 'Kifurushi cha maarifa';

  @override
  String introAssetBundleSubtitle(int count) {
    return 'Hifadhidata ya ulinganishi pamoja na PDF $count za miongozo.';
  }

  @override
  String get introWelcome => 'Karibu MAM-AI';

  @override
  String get introDescription =>
      'Majibu ya kuaminika ya kimatibabu, bila mtandao, daima tayari.';

  @override
  String get introPartnership => 'Kwa ushirikiano na';

  @override
  String get licenseTitle => 'Leseni ya Mfano wa Gemma';

  @override
  String get licenseIntro =>
      'Programu hii inatumia mfano wa Gemma 4 kwenye kifaa chako. Kabla ya kupakua, lazima usoma na kukubali Masharti ya Matumizi ya Gemma ya Google na Sera ya Matumizi Yaliyokatazwa.';

  @override
  String get licenseTermsText =>
      'Mfano wa Gemma hutolewa chini ya Masharti ya Matumizi ya Google yanayopatikana katika';

  @override
  String get licenseUsagePolicyLink =>
      'Sera ya matumizi yaliyokatazwa ya Gemma';

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
      'Hali ya kwenye kifaa haipatikani kwenye mfumo huu.';
}
