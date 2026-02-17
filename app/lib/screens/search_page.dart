import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// This is the search page. The user interacts with the model by typing in
/// the search bar or clicking one of the suggestion chips.
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
  /// Response from the LLM (summary)
  String? _latestMessage;

  /// Documents retrieved from RAG
  List<String> _retrievedDocuments = List.empty();

  static const platform = MethodChannel("io.github.mzsfighters.mam_ai/request_generation");
  static const latestMessageStream = EventChannel("io.github.mzsfighters.mam_ai/latest_message");
  StreamSubscription? _latestMessageSubscription;
  SearchController controller = SearchController();
  bool _searchedBefore = false;

  /// Request the model to generate a prompt - this calls into the Android code
  /// (see app/android/app/src/main/kotlin/com/example/app/MainActivity.kt)
  Future<void> _generateResponse(String prompt) async {
    try {
      setState(() {
        _searchedBefore = true;
        _latestMessage = null;
      });

      await platform.invokeMethod<int>("generateResponse", prompt);
    } on PlatformException catch (e) {
      debugPrint('Platform error while generating response: $e');
    }
  }

  void _startListeningForLatestMessage() {
    _latestMessageSubscription = latestMessageStream.receiveBroadcastStream().listen(_onLatestMessageUpdate);
  }

  /// Update the latest message & documents as the model generates
  void _onLatestMessageUpdate(value) {
    setState(() {
      if (value.containsKey("response")) {
        _latestMessage = value["response"];
      } else {
        List<Object?> docs = value["results"];
        _retrievedDocuments = docs.map<String>((a) => a as String).toList();
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
    _latestMessageSubscription?.cancel();
  }

  /// Called when the user clicks a chip or presses search
  void onSubmit(String text) {
    // For some reason, if we close an already closed view, it will make the
    // entire screen black - I think that this is probably poorly-isolated code
    // given that it affects the entire _screen_ and not only the widget it is
    // supposed to control
    if (controller.isOpen) {
      controller.closeView(text);
    } else {
      // We still want to set the text even if the search view is closed
      controller.text = text;
    }

    _generateResponse(text);
  }

  @override
  Widget build(BuildContext context) {
    // Some suggested prompt
    var examples = [
      "Baby continuous crying",
      "Preparing for home birth",
      "Infection risks childbirth",
      "Bleeding after delivery",
      "Newborn not breathing"
    ];
    var history = []; // Search history TBD

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_latestMessageSubscription == null) {
        _startListeningForLatestMessage();
      }
    });

    return Material(
      child: Scaffold(
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
              SizedBox(width: 10),
              const Text(
                'MAM-AI clinical search',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          centerTitle: true,
          backgroundColor: Colors.deepOrange,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SearchAnchor(
                shrinkWrap: true,
                searchController: controller,
                viewOnSubmitted: onSubmit,
                builder: (BuildContext context, SearchController controller) {
                  return SearchBar(
                    constraints: const BoxConstraints(minWidth: 360.0, minHeight: 56.0),
                    leading: Padding(
                      padding: const EdgeInsets.only(left: 8.0, top: 12.0, right: 0.0, bottom: 8.0),
                      child: Icon(Icons.search),
                    ),
                    controller: controller,
                    hintText: "Search in medical guidelines...",
                    onSubmitted: onSubmit,
                    onTap: controller.openView,
                    onChanged: (_) => controller.openView(),
                  );
                },
                suggestionsBuilder: (BuildContext context, SearchController controller) {
                  RegExp regex = RegExp(RegExp.escape(controller.text.toLowerCase()));
                  return history
                      .map((text) => SearchSuggestionTile(text, SuggestionType.history, onPressed: onSubmit))
                      .followedBy(examples.map((text) => SearchSuggestionTile(text, SuggestionType.example, onPressed: onSubmit)))
                      .where((tile) => regex.hasMatch(tile.text.toLowerCase()))
                      .toList();
                },
              ),
              const SizedBox(height: 16),

              Expanded(
                child: SingleChildScrollView(
                  child:
                    (_searchedBefore)
                      ? SearchOutput(summary: _latestMessage, retrievedDocuments: _retrievedDocuments)
                      : Container(
                        margin: const EdgeInsets.only(bottom: 20),
                        child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 5,
                            runSpacing: 5,
                            children: history
                                .map((text) => SearchSuggestionChip(text, SuggestionType.history, onPressed: onSubmit))
                                .followedBy(examples.map((text) => SearchSuggestionChip(text, SuggestionType.example, onPressed: onSubmit)))
                                .toList()
                        ),
                      ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

/// We have two types of suggestion chips - example & history. Only example
/// is used so far
enum SuggestionType {
  example,
  history,
}

/// A search suggestion appearing in the dropdown list
class SearchSuggestionTile extends StatelessWidget {
  const SearchSuggestionTile(this.text, this.type, {super.key, required this.onPressed});

  final String text;
  final Function(String) onPressed;
  final SuggestionType type;

  @override
  Widget build(BuildContext context) {
    Icon icon;
    Color? textColor;

    switch(type) {
      case SuggestionType.example:
        textColor = Color(0xff994000);
        icon = Icon(Icons.auto_awesome, color: textColor);
        break;

      case SuggestionType.history:
        icon = Icon(Icons.history);
        break;
    }

    return ListTile(
      leading: icon,
      title: Text(
        text,
        style: TextStyle(color: textColor)
      ),
      onTap: () => onPressed(text),
    );
  }
}

/// A search suggestion chip
class SearchSuggestionChip extends StatelessWidget {
  const SearchSuggestionChip(this.text, this.type, {super.key, required this.onPressed});

  final String text;
  final Function(String) onPressed;
  final SuggestionType type;

  @override
  Widget build(BuildContext context) {
    Icon icon;
    Color? bgColor;
    Color? textColor;
    Color borderColor;

    switch(type) {
      case SuggestionType.example:
        icon = Icon(Icons.auto_awesome);
        bgColor = Colors.orange[50];

        textColor = Color(0xffcc5500);
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
        label: Text(
          text,
        ),
        onPressed: () => onPressed(text),
      ),
    );
  }
}

/// The main widget for the search summary
class SearchOutput extends StatelessWidget {
  const SearchOutput({super.key, required this.summary, required this.retrievedDocuments});

  final String? summary;
  final List<String> retrievedDocuments;

  @override
  Widget build(BuildContext context) {
    if (summary == null) {
      return Center(child: SizedBox(width: 75, height: 75, child: CircularProgressIndicator(color: Color(0xffcc5500))));
    }

    final retrievedDocs = retrievedDocuments.map((doc) {
      return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.book),
                title: const Text('Information from guidelines'),
                contentPadding: const EdgeInsetsDirectional.only(start: 16.0, end: 24.0),
              ),
              Padding(
                padding: EdgeInsetsDirectional.only(start: 16.0, end: 24.0, bottom: 16.0),
                child: Text(doc, style: TextStyle(fontSize: 16)),
              )
            ],
          )
      );
    });

    Color lightOrange = Color(0xffff7f50);
    Color darkOrange = Color(0xffcc5500);

    return Column(
      children: [
        Card(
          elevation: 2.0,
          surfaceTintColor: lightOrange,
          shadowColor: lightOrange,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: Icon(Icons.auto_awesome, color: darkOrange, size: 40),
                title: const Text('Generated summary', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),),
                subtitle: RichText(text: TextSpan(
                    text: '⚠️ Read with care. ',
                    style: DefaultTextStyle.of(context).style,
                    children: [
                      TextSpan(
                          text: 'AI can make serious mistakes! ⚠️',
                          style: TextStyle(fontWeight: FontWeight.bold)
                      )
                    ])
                ),
                contentPadding: const EdgeInsetsDirectional.only(start: 16.0, end: 24.0),
              ),
              Padding(
                padding: EdgeInsetsDirectional.only(start: 16.0, end: 24.0, bottom: 16.0),
                child: MarkdownBlock(
                  data: summary!,
                  config: MarkdownConfig(
                    configs: [
                      PConfig(textStyle: TextStyle(fontSize: 18))
                    ]
                  ),
                ),
              )
            ],
          )
        ),
        ...retrievedDocs,
      ],
    );
  }
}
