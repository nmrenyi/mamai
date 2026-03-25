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
  String get tooltipCloudAI => 'Cloud AI (tap to switch to on-device)';

  @override
  String get tooltipOnDevice => 'On-device (tap to switch to cloud)';

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
  String introDownloadingModels(String percent) {
    return 'Downloading models ($percent%)';
  }

  @override
  String get introWelcome => 'Welcome to MAM-AI';

  @override
  String get introDescription =>
      'A clinical decision-support tool for nurse-midwives in Zanzibar. Offers fully offline, on-device answers grounded in medical guidelines — covering maternal health, obstetrics, and neonatal care — for reliable, private support at the point of care.';

  @override
  String get introPartnership => 'In partnership with';

  @override
  String get licenseTitle => 'Accept Gemma3n license';

  @override
  String get licenseIntro =>
      'Please read and accept Gemma3n\'s license and prohibited usage policy.';

  @override
  String get licenseTermsText =>
      'Gemma is provided under and subject to the Gemma Terms of Use found at';

  @override
  String get licenseUsagePolicyLink => 'Gemma3n usage policy';

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
      'On-device mode is not available here. Switch to Cloud AI to send messages.';

  @override
  String get switchToCloudAIAction => 'Use Cloud AI';

  @override
  String get errorNoApiKey =>
      'No API key configured. Rebuild with --dart-define=GEMINI_API_KEY=your_key to use Cloud AI.';

  @override
  String errorApiKeyInvalid(int code) {
    return 'API key is invalid or unauthorised (HTTP $code). Check your GEMINI_API_KEY.';
  }

  @override
  String get errorRateLimited =>
      'Too many requests — please wait a moment and try again.';

  @override
  String get errorNoInternet =>
      'Cannot reach Cloud AI. Check your internet connection.';

  @override
  String errorCloudUnavailable(int code) {
    return 'Cloud AI returned an error (HTTP $code). Please try again.';
  }
}
