// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appBarSubtitle => 'For nurse-midwives in Zanzibar';

  @override
  String get tooltipConversationHistory => 'Conversation history';

  @override
  String get tooltipNewConversation => 'New conversation';

  @override
  String get tooltipSearchEnabled => 'Search enabled';

  @override
  String get tooltipSearchDisabled => 'Search disabled';

  @override
  String get searchOn => 'Search ON';

  @override
  String get searchOff => 'Search OFF';

  @override
  String get dialogCancelGenerationTitle => 'Cancel previous generation?';

  @override
  String get dialogCancelGenerationContent =>
      'A response is still being generated for a previous conversation. Cancel it to send this message?';

  @override
  String get dialogWait => 'Wait';

  @override
  String get dialogCancelAndSend => 'Cancel and send';

  @override
  String get snackbarHistoryTruncated =>
      'Older messages were removed to fit the model\'s context window.';

  @override
  String snackbarResponseReady(String title) {
    return 'Response ready: \"$title\"';
  }

  @override
  String get snackbarView => 'View';

  @override
  String get emptyStateHeading => 'What do you need help with today?';

  @override
  String get emptyStateSubheading =>
      'Here to support you at the point of care.';

  @override
  String get exampleChip1 => 'How do I measure fundal height?';

  @override
  String get exampleChip2 =>
      'My patient\'s newborn won\'t latch, what do I do?';

  @override
  String get exampleChip3 =>
      'How do I care for the umbilical cord after birth?';

  @override
  String get exampleChip4 =>
      'When should I give iron supplements in pregnancy?';

  @override
  String get exampleChip5 => 'How much newborn weight loss is normal?';

  @override
  String get inputHint => 'Describe your clinical situation...';

  @override
  String get disclaimer =>
      'Always apply your clinical judgment. For emergencies, escalate immediately.';

  @override
  String get thinkingLabel => 'Thinking';

  @override
  String get generatingLabel => 'Generating response';

  @override
  String get responseCancelled => 'Response was interrupted.';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutDescription =>
      'A clinical decision-support tool for nurse-midwives in Zanzibar. Offers fully offline, on-device answers grounded in medical guidelines — covering maternal health, obstetrics, and neonatal care — for reliable, private support at the point of care.';

  @override
  String get aboutKnowledgeBundleTitle => 'Knowledge bundle';

  @override
  String get aboutKnowledgeBundleUnavailable =>
      'Bundle metadata is not available on this device yet.';

  @override
  String get aboutKnowledgeBundleVersionLabel => 'Version';

  @override
  String get aboutKnowledgeBundleDeployedLabel => 'Deployed';

  @override
  String get drawerAbout => 'About MAM-AI';

  @override
  String get drawerTitle => 'Past conversations';

  @override
  String get drawerNewConversation => 'New conversation';

  @override
  String get drawerNoConversations => 'No conversations yet';

  @override
  String timestampToday(String time) {
    return 'Today $time';
  }

  @override
  String get timestampYesterday => 'Yesterday';

  @override
  String get deleteConversationTitle => 'Delete conversation?';

  @override
  String deleteConversationContent(String title) {
    return 'Delete \"$title\"?';
  }

  @override
  String get dialogCancel => 'Cancel';

  @override
  String get dialogDelete => 'Delete';

  @override
  String get clearAllTitle => 'Clear all conversations?';

  @override
  String get clearAllContent =>
      'This will permanently delete all past conversations.';

  @override
  String get clearAllButton => 'Clear all';

  @override
  String get clearAllDrawerItem => 'Clear all conversations';

  @override
  String retrievedGuidelines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Retrieved $count guidelines',
      one: 'Retrieved 1 guideline',
    );
    return '$_temp0';
  }

  @override
  String get introCheckingLLM => 'Checking if the LLM is installed...';

  @override
  String get introLLMLoading =>
      'LLM loading (may take a while the first time)...';

  @override
  String get introStartChat => 'Start chat';

  @override
  String get introDownloadModels => 'Download models';

  @override
  String get introDownloadIncludesTitle => 'This setup will download';

  @override
  String get introDownloadSpeedLabel => 'Speed';

  @override
  String introDownloadFinishesIn(String time) {
    return 'finishing in $time';
  }

  @override
  String get introDownloadStatusQueued => 'Queued';

  @override
  String get introDownloadStatusStarting => 'Starting';

  @override
  String get introDownloadStatusReady => 'Ready';

  @override
  String get introDownloadStatusFinalizing => 'Unpacking bundle';

  @override
  String get introDownloadStatusDecompressing => 'Decompressing';

  @override
  String get introDownloadStatusScanning => 'Reading files';

  @override
  String get introDownloadStatusExtracting => 'Writing files';

  @override
  String get introDownloadStatusVerifying => 'Verifying';

  @override
  String introDownloadBundleDecompressing(String current, String total) {
    return 'Decompressing the bundle archive: $current of $total.';
  }

  @override
  String get introDownloadBundleScanning =>
      'Reading the bundle contents so the app can prepare the offline files.';

  @override
  String introDownloadBundleExtracting(String current, String total) {
    return 'Writing the embeddings database and guideline PDFs: $current of $total.';
  }

  @override
  String introDownloadBundleVerifying(int count) {
    return 'Checking that the embeddings database and $count guideline PDFs are ready.';
  }

  @override
  String introDownloadBundleParallel(int count) {
    return 'The knowledge bundle is already downloaded. The app is now unpacking the embeddings database and $count guideline PDFs while the remaining model files continue downloading.';
  }

  @override
  String introDownloadBundleOnly(int count) {
    return 'All downloads are finished. The app is now unpacking the embeddings database and $count guideline PDFs, then verifying the offline data.';
  }

  @override
  String get introAssetGemmaTitle => 'Gemma 4 on-device model';

  @override
  String get introAssetGemmaSubtitle =>
      'Main language model for chat responses.';

  @override
  String get introAssetGeckoTitle => 'Gecko embedding model';

  @override
  String get introAssetGeckoSubtitle =>
      'Used to find the most relevant guideline passages.';

  @override
  String get introAssetTokenizerTitle => 'SentencePiece tokenizer';

  @override
  String get introAssetTokenizerSubtitle =>
      'Tokenizer required by the embedding model.';

  @override
  String get introAssetBundleTitle => 'Knowledge bundle';

  @override
  String introAssetBundleSubtitle(int count) {
    return 'Embeddings database plus $count guideline PDFs.';
  }

  @override
  String get introWelcome => 'Welcome to MAM-AI';

  @override
  String get introDescription =>
      'Trusted clinical answers, offline and always ready.';

  @override
  String get introPartnership => 'In partnership with';

  @override
  String get licenseTitle => 'Gemma Model License';

  @override
  String get licenseIntro =>
      'This app runs the Gemma 4 model on your device. Before downloading, you must read and accept Google\'s Gemma Terms of Use and Prohibited Use Policy.';

  @override
  String get licenseTermsText =>
      'The Gemma model is provided under Google\'s Terms of Use at';

  @override
  String get licenseUsagePolicyLink => 'Gemma prohibited use policy';

  @override
  String get licenseAccept => 'Accept';

  @override
  String get licenseDeny => 'Deny';

  @override
  String get switchToSwahili => 'Kiswahili';

  @override
  String get switchToEnglish => 'English';

  @override
  String get errorOnDeviceUnavailable =>
      'On-device mode is not available on this platform.';
}
