import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ws/enum/ws_event_types.dart';
import 'package:flutter_ws/exceptions/failed_to_contact_websocket.dart';
import 'package:flutter_ws/global_state/list_state_container.dart';
import 'package:flutter_ws/model/indexing_info.dart';
import 'package:flutter_ws/model/query_result.dart';
import 'package:flutter_ws/model/video.dart';
import 'package:flutter_ws/section/about_section.dart';
import 'package:flutter_ws/section/download_section.dart';
import 'package:flutter_ws/section/overview_section.dart';
import 'package:flutter_ws/util/json_parser.dart';
import 'package:flutter_ws/util/text_styles.dart';
import 'package:flutter_ws/websocket/websocket.dart';
import 'package:flutter_ws/websocket/websocket_manager.dart';
import 'package:flutter_ws/widgets/bars/gradient_app_bar.dart';
import 'package:flutter_ws/widgets/bars/indexing_bar.dart';
import 'package:flutter_ws/widgets/bars/status_bar.dart';
import 'package:flutter_ws/widgets/filterMenu/filter_menu.dart';
import 'package:flutter_ws/widgets/filterMenu/search_filter.dart';
import 'package:flutter_ws/widgets/introSlider/intro_slider.dart';
import 'package:flutter_ws/widgets/videolist/video_list_view.dart';
import 'package:flutter_ws/widgets/videolist/videolist_util.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'global_state/appBar_state_container.dart';

void main() => runApp(new AppSharedStateContainer(child: new MyApp()));

class MyApp extends StatelessWidget {
  final TextEditingController textEditingController =
      new TextEditingController();

  @override
  Widget build(BuildContext context) {
    AppSharedStateContainer.of(context).initializeState(context);

    final title = 'MediathekViewMobile';

    //Setup global log levels
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((LogRecord rec) {
      print('${rec.level.name}: ${rec.time}: ${rec.message}');
    });

    Uuid uuid = new Uuid();

    return new MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: new ThemeData(
        textTheme: new TextTheme(
            subhead: subHeaderTextStyle,
            title: headerTextStyle,
            body1: body1TextStyle,
            body2: body2TextStyle,
            display1: hintTextStyle,
            button: buttonTextStyle),
        chipTheme: new ChipThemeData.fromDefaults(
            secondaryColor: Colors.black,
            labelStyle: subHeaderTextStyle,
            brightness: Brightness.dark),
        brightness: Brightness.light,
      ),
      title: title,
      home: new MyHomePage(
        key: new Key(uuid.v1()),
        title: title,
        textEditingController: textEditingController,
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final String title;
  final TextEditingController textEditingController;
  final PageController pageController;
  final Logger logger = new Logger('Main');

  MyHomePage(
      {Key key,
      @required this.title,
      this.pageController,
      this.textEditingController})
      : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return new HomePageState(this.textEditingController, this.logger);
  }
}

class HomePageState extends State<MyHomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  List<Video> videos;
  final Logger logger;

  //global state
  AppSharedState appWideState;

  //AppBar
  IconButton buttonOpenFilterMenu;
  String currentUserQueryInput;

  //Filter Menu
  Map<String, SearchFilter> searchFilters;
  bool filterMenuOpen;
  bool filterMenuChannelFilterIsOpen;

  //Websocket
  static WebsocketController websocketController;
  static Timer socketHealthTimer;
  bool websocketInitError;
  IndexingInfo indexingInfo;
  bool indexingError;
  bool refreshOperationRunning;
  Completer<Null> refreshCompleter;
  static const SHOW_CONNECTION_ISSUES_THRESHOLD = 3;
  int consecutiveWebsocketUnhealthyChecks;

  //Keys
  Key videoListKey;
  Key statusBarKey;
  Key indexingBarKey;

  //mock
  static Timer mockTimer;

  //Statusbar
  StatusBar statusBar;

  TabController _controller;

  /// Indicating the current displayed page
  /// 0: videoList
  /// 1: LiveTV
  /// 2: downloads
  /// 3: about
  int _page = 0;

  //search
  TextEditingController searchFieldController;
  bool scrolledToEndOfList;
  int lastAmountOfVideosRetrieved;
  int totalQueryResults = 0;

  //Tabs
  Widget videoSearchList;
  static DownloadSection downloadSection;
  AboutSection aboutSection;

  //intro slider
  SharedPreferences prefs;
  bool isFirstStart = false;

  HomePageState(this.searchFieldController, this.logger);

  @override
  void dispose() {
    logger.fine("Disposing Home Page & shutting down websocket connection");

    websocketController.stopPing();
    websocketController.closeWebsocketChannel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    videos = new List();
    searchFilters = new Map();
    filterMenuOpen = false;
    filterMenuChannelFilterIsOpen = false;
    websocketInitError = false;
    indexingInfo = null;
    indexingError = false;
    lastAmountOfVideosRetrieved = -1;
    refreshOperationRunning = false;
    scrolledToEndOfList = false;
    currentUserQueryInput = "";
    var inputListener = () => handleSearchInput();
    searchFieldController.addListener(inputListener);
    consecutiveWebsocketUnhealthyChecks = 0;

    //register Observer to react to android/ios lifecycle events
    WidgetsBinding.instance.addObserver(this);

    _controller = new TabController(length: 4, vsync: this);
    _controller.addListener(() => onUISectionChange());

    //Init tabs
    //liveTVSection = new LiveTVSection();
    aboutSection = new AboutSection();

    //keys
    Uuid uuid = new Uuid();
    videoListKey = new Key(uuid.v1());
    statusBarKey = new Key(uuid.v1());
    indexingBarKey = new Key(uuid.v1());

    websocketController = new WebsocketController(
        onDataReceived: onWebsocketData,
        onDone: onWebsocketDone,
        onError: onWebsocketError,
        onWebsocketChannelOpenedSuccessfully:
            onWebsocketChannelOpenedSuccessfully);
    websocketController.initializeWebsocket().then((Void) {
      currentUserQueryInput = searchFieldController.text;

      logger.fine("Firing initial query on home page init");
      websocketController.queryEntries(currentUserQueryInput, searchFilters);
    });

    startSocketHealthTimer();
    checkForFirstStart();
  }

  @override
  Widget build(BuildContext context) {
    appWideState = AppSharedStateContainer.of(context);

    if (isFirstStart) {
      return new IntroScreen(onDonePressed: () {
        setState(() {
          isFirstStart = false;
          prefs.setBool('firstStart', false);
        });
      });
    }

    if (downloadSection == null) {
      downloadSection = new DownloadSection(appWideState);
    }

    return new Scaffold(
      backgroundColor: Colors.grey[800],
      body: new TabBarView(
        controller: _controller,
        children: <Widget>[
          new OverviewSection(),
          getVideoSearchListWidget(),
          downloadSection,
          aboutSection == null ? new AboutSection() : aboutSection
        ],
      ),
      bottomNavigationBar: new Theme(
        data: Theme.of(context).copyWith(
            // sets the background color of the `BottomNavigationBar`
            canvasColor: Colors.black,
            // sets the active color of the `BottomNavigationBar` if `Brightness` is light
            primaryColor: Colors.red,
            textTheme: Theme.of(context).textTheme.copyWith(
                caption: new TextStyle(
                    color: Colors
                        .yellow))), // sets the inactive color of the `BottomNavigationBar`
        child: new BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _page,
          onTap: navigationTapped,
          items: [
            BottomNavigationBarItem(
                icon: Icon(
                  Icons.home,
                  color: Colors.white,
                ),
                activeIcon: Icon(
                  Icons.home,
                  color: Color(0xffffbf00),
                ),
                title: Text(
                  "Home",
                  style: new TextStyle(color: Colors.white, fontSize: 15.0),
                )),
            BottomNavigationBarItem(
                icon: Icon(
                  Icons.live_tv,
                  color: Colors.white,
                ),
                activeIcon: Icon(
                  Icons.live_tv,
                  color: Color(0xffffbf00),
                ),
                title: Text("Mediathek",
                    style: new TextStyle(color: Colors.white, fontSize: 15.0))),
            BottomNavigationBarItem(
                icon: Icon(
                  Icons.folder,
                  color: Colors.white,
                ),
                activeIcon: Icon(
                  Icons.folder,
                  color: Color(0xffffbf00),
                ),
                title: Text("Bibliothek",
                    style: new TextStyle(color: Colors.white, fontSize: 15.0))),
            BottomNavigationBarItem(
                icon: Icon(
                  Icons.info_outline,
                  color: Colors.white,
                ),
                activeIcon: Icon(
                  Icons.info_outline,
                  color: Color(0xffffbf00),
                ),
                title: Text("Info",
                    style: new TextStyle(color: Colors.white, fontSize: 15.0)))
          ],
        ),
      ),
    );
  }

  Widget getVideoSearchListWidget() {
    logger.fine("Rendering Video Search list");

    Widget videoSearchList = new SafeArea(
      child: new RefreshIndicator(
        onRefresh: _handleListRefresh,
        child: new Container(
          color: Colors.grey[800],
          child: new CustomScrollView(
            slivers: <Widget>[
              new SliverToBoxAdapter(
                child: new FilterBarSharedState(
                  child: new GradientAppBar(
                      this,
                      searchFieldController,
                      new FilterMenu(
                          searchFilters: searchFilters,
                          onFilterUpdated: _filterMenuUpdatedCallback,
                          onSingleFilterTapped: _singleFilterTappedCallback),
                      false,
                      videos.length,
                      totalQueryResults),
                ),
              ),
              new VideoListView(
                  key: videoListKey,
                  videos: videos,
                  amountOfVideosFetched: lastAmountOfVideosRetrieved,
                  queryEntries: onQueryEntries,
                  currentQuerySkip: websocketController.getCurrentSkip(),
                  totalResultSize: totalQueryResults,
                  mixin: this),
              new SliverToBoxAdapter(
                child: new StatusBar(
                    key: statusBarKey,
                    websocketInitError: websocketInitError,
                    videoListIsEmpty: videos.isEmpty,
                    lastAmountOfVideosRetrieved: lastAmountOfVideosRetrieved,
                    firstAppStartup: lastAmountOfVideosRetrieved < 0),
              ),
              new SliverToBoxAdapter(
                child: new IndexingBar(
                    key: indexingBarKey,
                    indexingError: indexingError,
                    info: indexingInfo),
              ),
            ],
          ),
        ),
      ),
    );
    return videoSearchList;
  }

  // Called when the user presses on of the BottomNavigationBarItems. Does not get triggered by a users swipe.
  void navigationTapped(int page) {
    logger.info("New Navigation Tapped: ---> Page " + page.toString());
    _controller.animateTo(page,
        duration: const Duration(milliseconds: 300), curve: Curves.ease);
    setState(() {
      this._page = page;
    });
  }

  /*
    Gets triggered whenever TabController changes page.
    This can be due to a user's swipe or via tab on the BottomNavigationBar
   */
  onUISectionChange() {
    if (this._page != _controller.index) {
      logger
          .info("UI Section Change: ---> Page " + _controller.index.toString());
      setState(() {
        this._page = _controller.index;
      });
    }
  }

  Future<Null> _handleListRefresh() async {
    logger.fine("Refreshing video list ...");
    refreshOperationRunning = true;
    //the completer will be completed when there are results & the flag == true
    refreshCompleter = new Completer<Null>();
    _createQueryWithClearedVideoList();

    return refreshCompleter.future;
  }

  // ----------CALLBACKS: WebsocketController----------------
  onWebsocketChannelOpenedSuccessfully() {
    if (this.websocketInitError) {
      setState(() {
        this.websocketInitError = false;
      });
    }
  }

  onWebsocketDone() {
    logger.info("Received a Done signal from the Websocket");
  }

  void onWebsocketError(FailedToContactWebsocketError error) {
    logger.info("Received a ERROR from the Websocket.", {error: error});
    showStatusBar();
  }

  void showStatusBar() {
    logger.fine("Ws Status: Errors retrieved: " +
        consecutiveWebsocketUnhealthyChecks.toString());
    consecutiveWebsocketUnhealthyChecks++;
    if (this.websocketInitError == false &&
        consecutiveWebsocketUnhealthyChecks ==
            SHOW_CONNECTION_ISSUES_THRESHOLD) {
      this.websocketInitError = true;
      if (mounted) setState(() {});
    }
  }

  void onWebsocketData(String data) {
    if (data == null) {
      logger.fine("Data received is null");
      setState(() {});
      return;
    }

    //determine event type
    String socketIOEventType =
        WebsocketHandler.parseSocketIOConnectionType(data);

    if (socketIOEventType != WebsocketConnectionTypes.UNKNOWN)
      logger.fine("Websocket: received response type: " + socketIOEventType);

    if (socketIOEventType == WebsocketConnectionTypes.RESULT) {
      if (refreshOperationRunning) {
        refreshOperationRunning = false;
        refreshCompleter.complete();
        videos.clear();
        logger.fine("Refresh operation finished.");
        HapticFeedback.lightImpact();
      }

      QueryResult queryResult = JSONParser.parseQueryResult(data);

      List<Video> newVideosFromQuery = queryResult.videos;
      totalQueryResults = queryResult.queryInfo.totalResults;
      lastAmountOfVideosRetrieved = newVideosFromQuery.length;

      int videoListLengthOld = videos.length;
      videos = VideoListUtil.sanitizeVideos(newVideosFromQuery, videos);
      int newVideosCount = videos.length - videoListLengthOld;

      if (newVideosCount == 0 && scrolledToEndOfList == false) {
        logger.fine("Scrolled to end of list & mounted: " + mounted.toString());
        scrolledToEndOfList = true;
        if (mounted) {
          setState(() {});
        }
        return;
      } else if (newVideosCount != 0) {
        // client side result filtering
        if (searchFilters["Länge"] != null) {
          videos =
              VideoListUtil.applyLengthFilter(videos, searchFilters["Länge"]);
        }
        int newVideosCount = videos.length - videoListLengthOld;

        logger.info('Received ' +
            newVideosCount.toString() +
            ' new video(s). Amount of videos in list ' +
            videos.length.toString());

        lastAmountOfVideosRetrieved = newVideosCount;
        scrolledToEndOfList == false;
        if (mounted) setState(() {});
      }
    } else if (socketIOEventType == WebsocketConnectionTypes.INDEX_STATE) {
      IndexingInfo indexingInfo = JSONParser.parseIndexingEvent(data);

      if (!indexingInfo.done && !indexingInfo.error) {
        setState(() {
          this.indexingError = false;
          this.indexingInfo = indexingInfo;
        });
      } else if (indexingInfo.error) {
        setState(() {
          this.indexingError = true;
        });
      } else {
        setState(() {
          this.indexingError = false;
          this.indexingInfo = null;
        });
      }
    } else {
      logger.fine("Received pong");
    }
  }

  // ----------CALLBACKS: From List View ----------------

  onQueryEntries() {
    websocketController.queryEntries(currentUserQueryInput, searchFilters);
  }

  // ---------- SEARCH Input ----------------

  void handleSearchInput() {
    if (currentUserQueryInput == searchFieldController.text) {
      logger.fine(
          "Current Query Input equals new query input - not querying again!");
      return;
    }

    _createQueryWithClearedVideoList();
  }

  void _createQuery() {
    currentUserQueryInput = searchFieldController.text;

    websocketController.queryEntries(currentUserQueryInput, searchFilters);
  }

  void _createQueryWithClearedVideoList() {
    logger.fine("Clearing video list");
    videos.clear();
    websocketController.resetSkip();

    if (mounted) setState(() {});
    _createQuery();
  }

  // ----------CALLBACKS: FILTER MENU----------------

  _filterMenuUpdatedCallback(SearchFilter newFilter) {
    //called whenever a filter in the menu gets a value
    if (this.searchFilters[newFilter.filterId] != null) {
      if (this.searchFilters[newFilter.filterId].filterValue !=
          newFilter.filterValue) {
        logger.fine("Changed filter text for filter with id " +
            newFilter.filterId.toString() +
            " detected. Old Value: " +
            this.searchFilters[newFilter.filterId].filterValue +
            " New : " +
            newFilter.filterValue);

        HapticFeedback.mediumImpact();

        searchFilters.remove(newFilter.filterId);
        if (newFilter.filterValue.isNotEmpty)
          this.searchFilters.putIfAbsent(newFilter.filterId, () => newFilter);
        //updates state internally
        _createQueryWithClearedVideoList();
      }
    } else if (newFilter.filterValue.isNotEmpty) {
      logger.fine("New filter with id " +
          newFilter.filterId.toString() +
          " detected with value " +
          newFilter.filterValue);

      HapticFeedback.mediumImpact();

      this.searchFilters.putIfAbsent(newFilter.filterId, () => newFilter);
      _createQueryWithClearedVideoList();
    }
  }

  _singleFilterTappedCallback(String id) {
    //remove filter from list and refresh state to trigger build of app bar and list!
    searchFilters.remove(id);
    HapticFeedback.mediumImpact();
    _createQueryWithClearedVideoList();
  }

  // ----------LIFECYCLE----------------
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    logger.fine("Observed Lifecycle change " + state.toString());
    if (state == AppLifecycleState.paused) {
      //TODO maybe dispose Tab controller here
      websocketController.stopPing();
      websocketController.closeWebsocketChannel();
    } else if (state == AppLifecycleState.resumed) {
      websocketController.initializeWebsocket();
    }
  }

  checkForFirstStart() async {
    prefs = await SharedPreferences.getInstance();
    var firstStart = prefs.getBool('firstStart');
    if (firstStart == null) {
      print("First start");
      setState(() {
        isFirstStart = true;
      });
    }
  }

  void startSocketHealthTimer() {
    if (socketHealthTimer == null || !socketHealthTimer.isActive) {
      Duration duration = new Duration(milliseconds: 5000);
      Timer.periodic(
        duration,
        (Timer t) {
          ConnectionState connectionState = websocketController.connectionState;

          if (connectionState == ConnectionState.active) {
            logger.fine("Ws connection is fine");
            consecutiveWebsocketUnhealthyChecks = 0;
            if (websocketInitError) {
              websocketInitError = false;
              if (mounted) setState(() {});
            }
          } else if (connectionState == ConnectionState.done ||
              connectionState == ConnectionState.none) {
            showStatusBar();

            logger.fine("Ws connection is " +
                connectionState.toString() +
                " and mounted: " +
                mounted.toString());

            if (mounted)
              websocketController
                  .initializeWebsocket()
                  .then((initializedSuccessfully) {
                if (initializedSuccessfully) {
                  consecutiveWebsocketUnhealthyChecks = 0;
                  logger.fine("WS connection stable again");
                  if (videos.isEmpty) {
                    _createQuery();
                  }
                } else {
                  logger.info("WS initialization failed");
                }
              });
          }
        },
      );
    }
  }

  mockIndexing() {
    if (mockTimer == null || !mockTimer.isActive) {
      var one = new Duration(seconds: 1);
      mockTimer = new Timer.periodic(one, (Timer t) {
        logger.fine("increase");
        if (indexingInfo == null) {
          indexingInfo = new IndexingInfo();
          indexingInfo.indexerProgress = 0.0;
        }
        if (indexingInfo.indexerProgress > 1) {
          setState(() {
            //Setting indexingInfo == null to ensure removal of progress indicator
            this.indexingError = false;
            this.indexingInfo = null;
          });
          mockTimer.cancel();
          return;
        }
        setState(() {
          indexingInfo.indexerProgress = indexingInfo.indexerProgress + 0.05;
        });
      });
    }
  }
}
