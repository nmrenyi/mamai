import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_sw.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('sw'),
  ];

  /// No description provided for @appBarSubtitle.
  ///
  /// In en, this message translates to:
  /// **'For nurse-midwives in Zanzibar'**
  String get appBarSubtitle;

  /// No description provided for @tooltipConversationHistory.
  ///
  /// In en, this message translates to:
  /// **'Conversation history'**
  String get tooltipConversationHistory;

  /// No description provided for @tooltipNewConversation.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get tooltipNewConversation;

  /// No description provided for @tooltipCloudAI.
  ///
  /// In en, this message translates to:
  /// **'Cloud AI (tap to switch to on-device)'**
  String get tooltipCloudAI;

  /// No description provided for @tooltipOnDevice.
  ///
  /// In en, this message translates to:
  /// **'On-device (tap to switch to cloud)'**
  String get tooltipOnDevice;

  /// No description provided for @tooltipSearchEnabled.
  ///
  /// In en, this message translates to:
  /// **'Search enabled'**
  String get tooltipSearchEnabled;

  /// No description provided for @tooltipSearchDisabled.
  ///
  /// In en, this message translates to:
  /// **'Search disabled'**
  String get tooltipSearchDisabled;

  /// No description provided for @searchOn.
  ///
  /// In en, this message translates to:
  /// **'Search ON'**
  String get searchOn;

  /// No description provided for @searchOff.
  ///
  /// In en, this message translates to:
  /// **'Search OFF'**
  String get searchOff;

  /// No description provided for @dialogCancelGenerationTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel previous generation?'**
  String get dialogCancelGenerationTitle;

  /// No description provided for @dialogCancelGenerationContent.
  ///
  /// In en, this message translates to:
  /// **'A response is still being generated for a previous conversation. Cancel it to send this message?'**
  String get dialogCancelGenerationContent;

  /// No description provided for @dialogWait.
  ///
  /// In en, this message translates to:
  /// **'Wait'**
  String get dialogWait;

  /// No description provided for @dialogCancelAndSend.
  ///
  /// In en, this message translates to:
  /// **'Cancel and send'**
  String get dialogCancelAndSend;

  /// No description provided for @snackbarHistoryTruncated.
  ///
  /// In en, this message translates to:
  /// **'Older messages were removed to fit the model\'s context window.'**
  String get snackbarHistoryTruncated;

  /// No description provided for @snackbarResponseReady.
  ///
  /// In en, this message translates to:
  /// **'Response ready: \"{title}\"'**
  String snackbarResponseReady(String title);

  /// No description provided for @snackbarView.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get snackbarView;

  /// No description provided for @emptyStateHeading.
  ///
  /// In en, this message translates to:
  /// **'What do you need help with today?'**
  String get emptyStateHeading;

  /// No description provided for @emptyStateSubheading.
  ///
  /// In en, this message translates to:
  /// **'Here to support you at the point of care.'**
  String get emptyStateSubheading;

  /// No description provided for @exampleChip1.
  ///
  /// In en, this message translates to:
  /// **'How do I measure fundal height?'**
  String get exampleChip1;

  /// No description provided for @exampleChip2.
  ///
  /// In en, this message translates to:
  /// **'My patient\'s newborn won\'t latch, what do I do?'**
  String get exampleChip2;

  /// No description provided for @exampleChip3.
  ///
  /// In en, this message translates to:
  /// **'How do I care for the umbilical cord after birth?'**
  String get exampleChip3;

  /// No description provided for @exampleChip4.
  ///
  /// In en, this message translates to:
  /// **'When should I give iron supplements in pregnancy?'**
  String get exampleChip4;

  /// No description provided for @exampleChip5.
  ///
  /// In en, this message translates to:
  /// **'How much newborn weight loss is normal?'**
  String get exampleChip5;

  /// No description provided for @inputHint.
  ///
  /// In en, this message translates to:
  /// **'Describe your clinical situation...'**
  String get inputHint;

  /// No description provided for @disclaimer.
  ///
  /// In en, this message translates to:
  /// **'Always apply your clinical judgment. For emergencies, escalate immediately.'**
  String get disclaimer;

  /// No description provided for @thinkingLabel.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get thinkingLabel;

  /// No description provided for @generatingLabel.
  ///
  /// In en, this message translates to:
  /// **'Generating response'**
  String get generatingLabel;

  /// No description provided for @responseCancelled.
  ///
  /// In en, this message translates to:
  /// **'Response was interrupted.'**
  String get responseCancelled;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutTitle;

  /// No description provided for @aboutDescription.
  ///
  /// In en, this message translates to:
  /// **'A clinical decision-support tool for nurse-midwives in Zanzibar. Offers fully offline, on-device answers grounded in medical guidelines — covering maternal health, obstetrics, and neonatal care — for reliable, private support at the point of care.'**
  String get aboutDescription;

  /// No description provided for @drawerAbout.
  ///
  /// In en, this message translates to:
  /// **'About MAM-AI'**
  String get drawerAbout;

  /// No description provided for @drawerTitle.
  ///
  /// In en, this message translates to:
  /// **'Past conversations'**
  String get drawerTitle;

  /// No description provided for @drawerNewConversation.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get drawerNewConversation;

  /// No description provided for @drawerNoConversations.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get drawerNoConversations;

  /// No description provided for @timestampToday.
  ///
  /// In en, this message translates to:
  /// **'Today {time}'**
  String timestampToday(String time);

  /// No description provided for @timestampYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get timestampYesterday;

  /// No description provided for @deleteConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation?'**
  String get deleteConversationTitle;

  /// No description provided for @deleteConversationContent.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{title}\"?'**
  String deleteConversationContent(String title);

  /// No description provided for @dialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get dialogCancel;

  /// No description provided for @dialogDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get dialogDelete;

  /// No description provided for @clearAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear all conversations?'**
  String get clearAllTitle;

  /// No description provided for @clearAllContent.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete all past conversations.'**
  String get clearAllContent;

  /// No description provided for @clearAllButton.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get clearAllButton;

  /// No description provided for @clearAllDrawerItem.
  ///
  /// In en, this message translates to:
  /// **'Clear all conversations'**
  String get clearAllDrawerItem;

  /// No description provided for @retrievedGuidelines.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Retrieved 1 guideline} other{Retrieved {count} guidelines}}'**
  String retrievedGuidelines(int count);

  /// No description provided for @introCheckingLLM.
  ///
  /// In en, this message translates to:
  /// **'Checking if the LLM is installed...'**
  String get introCheckingLLM;

  /// No description provided for @introLLMLoading.
  ///
  /// In en, this message translates to:
  /// **'LLM loading (may take a while the first time)...'**
  String get introLLMLoading;

  /// No description provided for @introStartChat.
  ///
  /// In en, this message translates to:
  /// **'Start chat'**
  String get introStartChat;

  /// No description provided for @introDownloadModels.
  ///
  /// In en, this message translates to:
  /// **'Download models'**
  String get introDownloadModels;

  /// No description provided for @introDownloadingModels.
  ///
  /// In en, this message translates to:
  /// **'Downloading models ({percent}%)'**
  String introDownloadingModels(String percent);

  /// No description provided for @introWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome to MAM-AI'**
  String get introWelcome;

  /// No description provided for @introDescription.
  ///
  /// In en, this message translates to:
  /// **'Trusted clinical answers, offline and always ready.'**
  String get introDescription;

  /// No description provided for @introPartnership.
  ///
  /// In en, this message translates to:
  /// **'In partnership with'**
  String get introPartnership;

  /// No description provided for @licenseTitle.
  ///
  /// In en, this message translates to:
  /// **'Accept Gemma3n license'**
  String get licenseTitle;

  /// No description provided for @licenseIntro.
  ///
  /// In en, this message translates to:
  /// **'Please read and accept Gemma3n\'s license and prohibited usage policy.'**
  String get licenseIntro;

  /// No description provided for @licenseTermsText.
  ///
  /// In en, this message translates to:
  /// **'Gemma is provided under and subject to the Gemma Terms of Use found at'**
  String get licenseTermsText;

  /// No description provided for @licenseUsagePolicyLink.
  ///
  /// In en, this message translates to:
  /// **'Gemma3n usage policy'**
  String get licenseUsagePolicyLink;

  /// No description provided for @licenseAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get licenseAccept;

  /// No description provided for @licenseDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get licenseDeny;

  /// No description provided for @switchToSwahili.
  ///
  /// In en, this message translates to:
  /// **'Kiswahili'**
  String get switchToSwahili;

  /// No description provided for @switchToEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get switchToEnglish;

  /// No description provided for @errorOnDeviceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'On-device mode is not available here. Switch to Cloud AI to send messages.'**
  String get errorOnDeviceUnavailable;

  /// No description provided for @switchToCloudAIAction.
  ///
  /// In en, this message translates to:
  /// **'Use Cloud AI'**
  String get switchToCloudAIAction;

  /// No description provided for @errorNoApiKey.
  ///
  /// In en, this message translates to:
  /// **'No API key configured. Rebuild with --dart-define=GEMINI_API_KEY=your_key to use Cloud AI.'**
  String get errorNoApiKey;

  /// No description provided for @errorApiKeyInvalid.
  ///
  /// In en, this message translates to:
  /// **'API key is invalid or unauthorised (HTTP {code}). Check your GEMINI_API_KEY.'**
  String errorApiKeyInvalid(int code);

  /// No description provided for @errorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many requests — please wait a moment and try again.'**
  String get errorRateLimited;

  /// No description provided for @errorNoInternet.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach Cloud AI. Check your internet connection.'**
  String get errorNoInternet;

  /// No description provided for @errorCloudUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Cloud AI returned an error (HTTP {code}). Please try again.'**
  String errorCloudUnavailable(int code);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'sw'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'sw':
      return AppLocalizationsSw();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
