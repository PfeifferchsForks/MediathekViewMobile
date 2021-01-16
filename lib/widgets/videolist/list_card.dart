import 'dart:convert';
import 'dart:ui';

import 'package:connectivity/connectivity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_ws/database/database_manager.dart';
import 'package:flutter_ws/database/video_entity.dart';
import 'package:flutter_ws/database/video_progress_entity.dart';
import 'package:flutter_ws/global_state/list_state_container.dart';
import 'package:flutter_ws/model/video.dart';
import 'package:flutter_ws/model/video_rating.dart';
import 'package:flutter_ws/model/video_rating_insert.dart';
import 'package:flutter_ws/platform_channels/download_manager_flutter.dart';
import 'package:flutter_ws/util/device_information.dart';
import 'package:flutter_ws/util/rating_util.dart';
import 'package:flutter_ws/util/show_snackbar.dart';
import 'package:flutter_ws/widgets/bars/playback_progress_bar.dart';
import 'package:flutter_ws/widgets/videolist/channel_thumbnail.dart';
import 'package:flutter_ws/widgets/videolist/rating_bar.dart';
import 'package:flutter_ws/widgets/videolist/star_rating.dart';
import 'package:flutter_ws/widgets/videolist/util/util.dart';
import 'package:flutter_ws/widgets/videolist/video_description.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'download_switch.dart';

class ListCard extends StatefulWidget {
  final Logger logger = new Logger('VideoWidget');
  final String channelPictureImagePath;
  final Video video;

  ListCard(
      {Key key, @required this.channelPictureImagePath, @required this.video})
      : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return new _ListCardState();
  }
}

class _ListCardState extends State<ListCard> {
  static const downloadManagerIdentifier = 0;
  BuildContext context;
  AppSharedState appWideState;
  bool modalBottomScreenIsShown = false;
  bool isDownloadedAlready = false;
  VideoEntity entity;
  bool isCurrentlyDownloading = false;
  DownloadTaskStatus currentStatus;
  double progress;
  DownloadManager downloadManager;
  DatabaseManager databaseManager;
  GlobalKey _keyListRow;
  VideoRating rating;
  VideoProgressEntity videoProgressEntity;

  @override
  void dispose() {
    super.dispose();
    widget.logger.fine("Disposing list-card for video with title " +
        widget.video.title +
        " and id " +
        widget.video.id);

    downloadManager.unsubscribe(widget.video.id, downloadManagerIdentifier);
  }

  @override
  Widget build(BuildContext context) {
    this.context = context;
    appWideState = AppSharedStateContainer.of(context);
    downloadManager = appWideState.appState.downloadManager;
    databaseManager = appWideState.appState.databaseManager;
    VideoListState videoListState = appWideState.videoListState;
    Orientation orientation = MediaQuery.of(context).orientation;
    rating = appWideState.appState.ratingCache[widget.video.id];

    subscribeToProgressChannel();
    loadCurrentStatusFromDatabase(widget.video.id);

    bool isExtendet = false;
    if (videoListState != null) {
      Set<String> extendetTiles = videoListState.extendetListTiles;
      isExtendet = extendetTiles.contains(widget.video.id);
    }

    Uuid uuid = new Uuid();

    final cardContent = new Column(
      key: new Key(uuid.v1()),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        new Container(key: new Key(uuid.v1()), height: 4.0),
        new Flexible(
          key: new Key(uuid.v1()),
          child: new Container(
            key: new Key(uuid.v1()),
            margin: new EdgeInsets.only(left: 40.0, right: 12.0),
            child: new Text(
              widget.video.topic,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: Theme.of(context)
                  .textTheme
                  .title
                  .copyWith(color: Colors.black),
            ),
          ),
        ),
        new Container(key: new Key(uuid.v1()), height: 10.0),
        new Flexible(
          key: new Key(uuid.v1()),
          child: new Container(
            key: new Key(uuid.v1()),
            margin: new EdgeInsets.only(left: 40.0, right: 12.0),
            child: new Text(
              widget.video.title,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: Theme.of(context)
                  .textTheme
                  .subhead
                  .copyWith(color: Colors.black),
            ),
          ),
        ),
        isExtendet == true
            ? new Container(
                key: new Key(uuid.v1()),
                margin:
                    new EdgeInsets.symmetric(vertical: 8.0, horizontal: 40.0),
                height: 2.0,
                color: Colors.grey)
            : new Container(
                key: new Key(uuid.v1()),
                padding: new EdgeInsets.only(left: 40.0, right: 12.0),
              ),
        new Column(
          key: new Key(uuid.v1()),
          children: <Widget>[
            new Padding(
              padding: new EdgeInsets.only(top: 12.0, bottom: 12.0),
              child: Stack(
                children: <Widget>[
                  /*new VideoPreviewAdapter(widget.video, true, true,
                      defaultImageAssetPath: widget.channelPictureImagePath),
                 */
                  new Positioned(
                    bottom: 0.0,
                    left: 0.0,
                    right: 0.0,
                    child: new Opacity(
                      opacity: 0.8,
                      child: new Column(
                        children: <Widget>[
                          // Playback Progress
                          videoProgressEntity != null
                              ? PlaybackProgressBar(
                                  videoProgressEntity.progress,
                                  int.tryParse(
                                      widget.video.duration.toString()),
                                  true)
                              : new Container(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            new RatingBar(
                isExtendet,
                rating,
                widget.video,
                Theme.of(context)
                    .textTheme
                    .body1
                    .copyWith(color: Colors.black, fontSize: 14.0),
                DeviceInformation.isTablet(context)
                    ? false
                    : orientation == Orientation.portrait
                        ? true
                        : false,
                true, ratingChanged:
                    (bool needsRemoteSync, VideoRating updatedRating) {
              if (needsRemoteSync) {
                uploadRating(updatedRating);
              }
              if (mounted) {
                setState(() {});
              }
            }),
            new DownloadSwitch(
                appWideState,
                widget.video,
                isCurrentlyDownloading,
                isDownloadedAlready,
                appWideState.appState.downloadManager,
                DeviceInformation.isTablet(context)),
          ],
        ),
      ],
    );

    final card = ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(10.0)),
      child: new Container(
        child: cardContent,
        decoration: new BoxDecoration(
          color: Colors.white,
          shape: BoxShape.rectangle,
        ),
      ),
    );

    //used to determine position on screen to place description popup correctly
    _keyListRow = GlobalKey();

    return new Container(
      key: _keyListRow,
      margin: const EdgeInsets.symmetric(
        horizontal: 4.0,
      ),
      child: new Stack(
        children: <Widget>[
          new GestureDetector(onTap: _handleTap, child: card),
          isExtendet
              ? new Container()
              : new Positioned.fill(
                  left: 20.0,
                  child: new Material(
                      color: Colors.transparent,
                      child: new InkWell(
                          onTap: _handleTap, onLongPress: showDescription)),
                ),
          widget.channelPictureImagePath.isNotEmpty
              ? new Positioned(
                  left: 5.0,
                  bottom: 5.0,
                  child: new ChannelThumbnail(
                      widget.channelPictureImagePath, isDownloadedAlready),
                )
              : new Container(),
          isExtendet || rating == null
              ? new Container()
              : new Positioned(
                  right: 20.0,
                  child: new StarRating(
                    rating,
                    widget.video,
                    true,
                    size: 18.0,
                    onRatingChanged:
                        (bool needsRemoteSync, VideoRating updatedRating) {
                      if (needsRemoteSync) {
                        uploadRating(updatedRating);
                      }
                      if (mounted) {
                        setState(() {});
                      }
                    },
                  ),
                )
        ],
      ),
    );
  }

  void _handleTap() {
    widget.logger.info("handle tab on tile");
    appWideState.updateExtendetListTile(widget.video.id);
    //only rerender this tile, not the whole app state!
    setState(() {});
  }

  showDescription() {
    double distanceOfRowToStart = determineDistanceOfRowToStart();
    HapticFeedback.mediumImpact();
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return new VideoDescription(
            widget.video, widget.channelPictureImagePath, distanceOfRowToStart);
      },
    );
  }

  double determineDistanceOfRowToStart() {
    final RenderBox renderBox = _keyListRow.currentContext.findRenderObject();
    final position = renderBox.localToGlobal(Offset.zero);
    return position.distance;
  }

  void onDownloadStateChanged(String videoId, DownloadTaskStatus updatedStatus,
      double updatedProgress) {
    widget.logger.info("Download: " +
        widget.video.title +
        " status: " +
        updatedStatus.toString() +
        " progress: " +
        updatedProgress.toString());

    progress = updatedProgress;

    updateStatus(updatedStatus, videoId);
  }

  void updateStatus(DownloadTaskStatus updatedStatus, String videoId) {
    if (mounted) {
      setState(() {
        currentStatus = updatedStatus;
      });
    } else {
      widget.logger.fine("Not updating status for Video  " +
          videoId +
          " - downloadCardBody not mounted");
    }
  }

  void subscribeToProgressChannel() {
    downloadManager.subscribe(
        widget.video.id,
        onDownloadStateChanged,
        onDownloaderComplete,
        onDownloaderFailed,
        onSubscriptionCanceled,
        downloadManagerIdentifier);
  }

  void onDownloaderFailed(String videoId) {
    widget.logger
        .info("Download video: " + videoId + " received 'failed' signal");
    // SnackbarActions.showError(context, ERROR_MSG_DOWNLOAD_FAILED);
    updateStatus(DownloadTaskStatus.failed, videoId);
  }

  void onDownloaderComplete(String videoId) {
    widget.logger
        .info("Download video: " + videoId + " received 'complete' signal");
    updateStatus(DownloadTaskStatus.complete, videoId);
  }

  void onSubscriptionCanceled(String videoId) {
    widget.logger
        .info("Download video: " + videoId + " received 'cancled' signal");
    updateStatus(DownloadTaskStatus.canceled, videoId);
  }

  void loadCurrentStatusFromDatabase(String videoId) async {
    if (videoProgressEntity == null) {
      appWideState.appState.databaseManager
          .getVideoProgressEntity(videoId)
          .then((entity) {
        if (entity != null) {
          videoProgressEntity = entity;
          if (mounted) {
            setState(() {});
          }
        }
      });
    }

    VideoEntity entity = await downloadManager.isAlreadyDownloaded(videoId);
    if (entity != null) {
      widget.logger.info("Video with name  " +
          widget.video.title +
          " and id " +
          videoId +
          " is downloaded already");
      this.entity = entity;
      if (!isDownloadedAlready) {
        isDownloadedAlready = true;
        isCurrentlyDownloading = false;
        currentStatus = null;
        if (mounted) {
          setState(() {});
        }
      }
      return;
    }

    if (await downloadManager.isCurrentlyDownloading(videoId) != null) {
      widget.logger.fine("Video with name  " +
          widget.video.title +
          " and id " +
          videoId +
          " is currently downloading");
      if (!isCurrentlyDownloading) {
        isDownloadedAlready = false;
        isCurrentlyDownloading = true;
        currentStatus = DownloadTaskStatus.running;

        if (mounted) {
          setState(() {});
        }
      }
    }
  }

  void onDownloadRequested() async {
    var connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult == ConnectivityResult.none) {
      SnackbarActions.showError(context, ERROR_MSG_NO_INTERNET);
      updateStatus(DownloadTaskStatus.failed, widget.video.id);
      return;
    }

    // also check if video url is accessible
    final response = await http.head(widget.video.url_video);

    if (response.statusCode >= 300) {
      widget.logger.info("Url is not accessible: " +
          widget.video.url_video.toString() +
          ". Status code: " +
          response.statusCode.toString() +
          ". Reason: " +
          response.reasonPhrase);

      SnackbarActions.showError(context, ERROR_MSG_NOT_AVAILABLE);
      updateStatus(DownloadTaskStatus.failed, widget.video.id);
      return;
    }

    subscribeToProgressChannel();
    // start download animation right away.
    onDownloadStateChanged(widget.video.id, DownloadTaskStatus.enqueued, -1);

    // check for filesystem permissions
    // if user grants permission, start downloading right away
    if (!appWideState.appState.hasFilesystemPermission) {
      appWideState.appState.downloadManager
          .checkAndRequestFilesystemPermissions(appWideState, widget.video);
      return;
    }

    downloadManager
        .downloadFile(widget.video)
        .then((video) => widget.logger.info("Downloaded request successfull"),
            onError: (e) {
      widget.logger.severe("Error starting download: " +
          widget.video.title +
          ". Error:  " +
          e.toString());
    });
  }

  void onDeleteRequested() {
    downloadManager
        .deleteVideo(widget.video.id)
        .then((bool deletedSuccessfully) {
      if (!deletedSuccessfully) {
        widget.logger
            .severe("Failed to delete video with title " + widget.video.title);
      }
      isDownloadedAlready = false;
      isCurrentlyDownloading = false;
      currentStatus = null;
      progress = null;
      if (mounted) {
        setState(() {});
      }
    });
  }

  void uploadRating(VideoRating rating) async {
    widget.logger.fine("Persisting rating in the cloud");
    if (rating == null) {
      return;
    }

    if (rating.local_user_rating == null) {
      widget.logger.info("Local user rating is null");
      return;
    }

    if (rating.local_user_rating == rating.local_user_rating_saved_from_db) {
      return;
    }

    if (rating.lastRemoteInsertRating != null &&
        rating.lastRemoteInsertRating == rating.local_user_rating) {
      widget.logger.info("Stopped duplicate cloud function call");
      return;
    }

    rating.lastRemoteInsertRating = rating.local_user_rating;

    String ratingUrl;
    double ratingValue;
    if (rating.rating_count == 1 &&
        rating.local_user_rating_saved_from_db == null) {
      widget.logger.info(
          "Add new rating (insert): " + rating.local_user_rating.toString());

      ratingValue = rating.local_user_rating;
      ratingUrl = await RatingUtil.getInsertRatingUrl();
    } else if (rating.rating_count > 1 &&
        rating.local_user_rating_saved_from_db == null) {
      widget.logger.info(
          "Add a new rating (update): " + rating.local_user_rating.toString());

      ratingValue = rating.local_user_rating;
      ratingUrl = await RatingUtil.getUpdateRatingUrl();
    } else if (rating.local_user_rating_saved_from_db != null) {
      var diff =
          rating.local_user_rating - rating.local_user_rating_saved_from_db;

      widget.logger.info("Add a new rating (diff): " + diff.toString());

      ratingValue = diff;
      ratingUrl = await RatingUtil.getInsertDifRatingUrl();
    }

    if (ratingUrl == null) {
      widget.logger.warning("Should not happen when inserting rating");
      return;
    }

    VideoRatingInsert userRating = new VideoRatingInsert(
        rating.video_id,
        ratingValue,
        rating.channel,
        rating.topic,
        rating.description,
        rating.title,
        rating.timestamp,
        rating.duration,
        rating.size,
        rating.url_video);
    final response =
        await http.post(ratingUrl, body: json.encode(userRating.toMap()));
    if (response.statusCode == 200) {
      appWideState.appState.ratingCache.update(rating.video_id, (old) {
        old.local_user_rating_saved_from_db = old.local_user_rating;
        return old;
      });

      widget.logger.info("Remote rating successful for rating: " +
          rating.local_user_rating.toString());
    } else {
      widget.logger.warning("Failed to Insert rating for video " +
          rating.video_id +
          " Response Code: " +
          response.statusCode.toString() +
          "Error: " +
          response.reasonPhrase);
    }
  }
}
