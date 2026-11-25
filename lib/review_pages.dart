import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'lightnovel/lightnovel_account.dart';
import 'lightnovel/lightnovel_client.dart';
import 'lightnovel/lightnovel_reviews.dart';
import 'local_platform.dart';
import 'online_features.dart';
import 'online_media.dart';
import 'read_only_text.dart';
import 'reader_illustrations.dart';
import 'review_content.dart';
import 'review_markup.dart';

String _describeReviewError(LightNovelAccount? account, Object error) {
  if (account != null) {
    if (error is LightNovelApiError && account.errorCode == null) {
      return error.message;
    }
    if (error is LightNovelHttpException &&
        account.errorCode?.call(error) == null) {
      return error.message;
    }
    return account.formatError(error);
  }
  if (error is LightNovelApiError) return error.message;
  if (error is LightNovelHttpException) return error.message;
  return LightNovelAccount.describeError(error);
}

class BookCommunityActions extends StatelessWidget {
  const BookCommunityActions({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;

  Future<bool> _login(BuildContext context, LightNovelAccount account) async {
    if (!account.authenticated) {
      AppHaptics.play(context, HapticCue.action);
      await pushNovelPage<void>(
        context,
        OnlineAccountPage(
          account: account,
          state: state,
          repository: repository,
        ),
        reduceMotion: state.reduceMotion,
      );
    }
    return context.mounted && account.authenticated;
  }

  Future<void> _saveToCloud(
    BuildContext context,
    LightNovelAccount account,
  ) async {
    if (account.busy || !await _login(context, account)) return;
    try {
      await account.addCloud(novel.id);
      if (context.mounted) {
        showNovelFeedback(context, '已收藏到云书架', haptic: HapticCue.success);
      }
    } catch (error) {
      if (context.mounted) {
        showNovelFeedback(
          context,
          _describeReviewError(account, error),
          haptic: HapticCue.error,
        );
      }
    }
  }

  Future<void> _share(BuildContext context) async {
    final url = 'https://www.lightnovel.fun/cn/book/${novel.id}';
    final text = novel.author.trim().isNotEmpty
        ? '${novel.title}\n${novel.author}\n$url'
        : '${novel.title}\n$url';
    try {
      if (LocalPlatform.android) {
        await LocalPlatform.shareText(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) showNovelFeedback(context, '图书信息已复制');
      }
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '分享未完成，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final features = OnlineFeaturesScope.maybeOf(context);
    if (features == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: features.account,
      builder: (context, _) {
        final actions = [
          GlassTextButton(
            key: const ValueKey('detail-cloud-save'),
            haptic: null,
            compact: true,
            onPressed: features.account.busy
                ? null
                : () => _saveToCloud(context, features.account),
            child: const AppText('云端收藏'),
          ),
          GlassTextButton(
            key: const ValueKey('detail-reviews'),
            compact: true,
            child: const AppText('评论'),
            onPressed: () => pushNovelPage<void>(
              context,
              OnlineReviewsPage(
                novel: novel,
                account: features.account,
                state: state,
                repository: repository,
              ),
              reduceMotion: state.reduceMotion,
            ),
          ),
          GlassTextButton(
            key: const ValueKey('detail-share'),
            compact: true,
            child: const AppText('分享'),
            onPressed: () => _share(context),
          ),
        ];
        final row = Row(
          key: const ValueKey('detail-community-actions'),
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < actions.length; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              actions[index],
            ],
          ],
        );
        return AppScrollHaptics(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: row,
          ),
        );
      },
    );
  }
}

class OnlineReviewsPage extends StatefulWidget {
  const OnlineReviewsPage({
    super.key,
    required this.novel,
    required this.account,
    required this.state,
    required this.repository,
    this.thread,
    this.feed,
    this.onPosted,
    this.apiCall,
  });
  final Novel novel;
  final LightNovelAccount account;
  final LibraryState state;
  final NovelRepository repository;
  final LightNovelComment? thread;
  final LightNovelReviewFeed? feed;
  final VoidCallback? onPosted;
  final LightNovelApiCall? apiCall;

  @override
  State<OnlineReviewsPage> createState() => _OnlineReviewsPageState();
}

class _OnlineReviewsPageState extends State<OnlineReviewsPage> {
  late String _view;
  late String _sort;
  final Map<String, LightNovelReviewFeed> _ownedFeeds = {};
  final Set<int> _likingIds = {};
  final Set<int> _deletingIds = {};
  late LightNovelEmojiCatalog _emojis;

  LightNovelApiCall get _effectiveApiCall =>
      widget.apiCall ?? widget.account.apiCall;

  String get _defaultThreadView =>
      widget.thread != null &&
          (widget.thread!.ratingStars > 0 || widget.thread!.type == 'rating')
      ? 'rating'
      : '';

  LightNovelReviewFeed _createFeed(String view) => LightNovelReviewFeed(
    bookId: widget.novel.id,
    view: view,
    commentId: widget.thread?.id ?? 0,
    commentSort: _sort,
    apiCall: _effectiveApiCall,
    securityKeyProvider: () => widget.account.securityKey,
    errorCode: widget.account.errorCode,
    errorMessage: widget.account.errorMessage,
    onAuthExpired: () => unawaited(widget.account.handleSessionExpired()),
  );

  LightNovelReviewFeed get _activeFeed {
    final injected = widget.feed;
    if (injected != null && (widget.thread != null || injected.view == _view)) {
      return injected;
    }
    return _ownedFeeds.putIfAbsent(_view, () => _createFeed(_view));
  }

  @override
  void initState() {
    super.initState();
    _view = widget.feed?.view ?? _defaultThreadView;
    _sort = widget.feed?.commentSort ?? 'hot';
    _emojis = LightNovelEmojiCatalog.cached ?? LightNovelEmojiCatalog.empty;
    if (widget.feed == null || widget.feed!.page == 0) {
      unawaited(_activeFeed.load());
    }
    if (LightNovelEmojiCatalog.cached == null &&
        (widget.apiCall != null || widget.feed == null)) {
      unawaited(_loadEmojis());
    }
  }

  Future<void> _loadEmojis() async {
    try {
      final catalog = await LightNovelEmojiCatalog.loadShared(
        _effectiveApiCall,
      );
      if (mounted) setState(() => _emojis = catalog);
    } catch (_) {
      // Missing/offline emoji metadata falls back to plain tokens cleanly.
    }
  }

  @override
  void dispose() {
    for (final feed in _ownedFeeds.values) {
      feed.dispose();
    }
    super.dispose();
  }

  Future<bool> _ensureAuthenticated({bool requireProfile = false}) async {
    if (!widget.account.authenticated) {
      await pushNovelPage<void>(
        context,
        OnlineAccountPage(
          account: widget.account,
          state: widget.state,
          repository: widget.repository,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    }
    if (!mounted || !widget.account.authenticated) return false;
    if (requireProfile && widget.account.profile == null) {
      try {
        await widget.account.refreshProfile();
      } catch (error) {
        if (mounted) {
          showNovelFeedback(
            context,
            _describeReviewError(widget.account, error),
          );
        }
        return false;
      }
      if (!mounted) return false;
    }
    return true;
  }

  void _setView(String nextView) {
    if (widget.thread != null || _view == nextView) return;
    setState(() => _view = nextView);
    final feed = _activeFeed;
    if (feed.commentSort != _sort) {
      unawaited(feed.setSort(_sort));
    } else if (feed.page == 0 && !feed.loading) {
      unawaited(feed.load());
    }
  }

  void _setSort(String nextSort) {
    if (_sort == nextSort) return;
    setState(() => _sort = nextSort);
    unawaited(_activeFeed.setSort(nextSort));
  }

  Future<void> _compose({LightNovelComment? replyTarget}) async {
    if (widget.account.busy) return;
    if (!await _ensureAuthenticated(requireProfile: true)) return;
    if (!mounted) return;
    final result = await pushNovelPage<Object?>(
      context,
      ReviewComposerPage(
        novel: widget.novel,
        account: widget.account,
        reduceMotion: widget.state.reduceMotion,
        thread: widget.thread,
        replyTarget: replyTarget,
        view: _view,
      ),
      reduceMotion: widget.state.reduceMotion,
    );
    if (!mounted || result == null || result == false) return;

    final postedComment = result is LightNovelComment ? result : null;
    final isRating =
        widget.thread == null &&
        (_view == 'rating' || (postedComment?.ratingStars ?? 0) > 0);
    showNovelFeedback(
      context,
      widget.thread != null
          ? '回复已发表'
          : isRating
          ? '评分评价已发表'
          : '评论已发表',
    );
    widget.onPosted?.call();

    if (postedComment != null) {
      if (widget.thread == null &&
          postedComment.ratingStars > 0 &&
          _view != 'rating') {
        setState(() => _view = 'rating');
        final targetFeed = _activeFeed;
        if (targetFeed.page == 0 && !targetFeed.loading) {
          await targetFeed.load();
        }
        if (mounted) targetFeed.insertLocalComment(postedComment);
      } else {
        _activeFeed.insertLocalComment(postedComment);
      }
    } else if (widget.feed == null) {
      unawaited(_activeFeed.load(refresh: true));
    }
  }

  Future<void> _toggleLike(LightNovelComment comment) async {
    if (_likingIds.contains(comment.id)) return;
    if (!await _ensureAuthenticated()) return;
    if (!mounted) return;
    _likingIds.add(comment.id);
    final feed = _activeFeed;
    try {
      await feed.toggleLike(
        comment,
        persist: (nextLiked) => widget.account.likeComment(
          bookId: widget.novel.id,
          commentId: comment.id,
          like: nextLiked,
          rootCommentId: comment.rootCommentId,
          volumeId: feed.volumeId,
          chapterId: feed.chapterId,
          view: feed.view,
        ),
      );
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          _describeReviewError(widget.account, error),
          haptic: HapticCue.error,
        );
      }
    } finally {
      _likingIds.remove(comment.id);
    }
  }

  Future<void> _deleteComment(LightNovelComment comment) async {
    if (_deletingIds.contains(comment.id)) return;
    if (!await _ensureAuthenticated()) return;
    if (!mounted) return;
    final confirmed = await confirmNovelAction(
      context,
      title: '删除评论？',
      message: '删除后不可恢复。',
      confirmLabel: '删除',
      reduceMotion: widget.state.reduceMotion,
    );
    if (!confirmed || !mounted) return;
    _deletingIds.add(comment.id);
    final feed = _activeFeed;
    try {
      await widget.account.deleteComment(
        bookId: widget.novel.id,
        commentId: comment.id,
        rootCommentId: comment.rootCommentId,
        volumeId: feed.volumeId,
        chapterId: feed.chapterId,
        view: feed.view,
      );
      feed.removeLocalComment(comment.id);
      if (mounted) {
        showNovelFeedback(context, '评论已删除');
        widget.onPosted?.call();
        if (widget.thread != null && comment.id == widget.thread!.id) {
          Navigator.pop(context, comment.id);
        }
      }
    } catch (error) {
      if (mounted) {
        showNovelFeedback(
          context,
          _describeReviewError(widget.account, error),
          haptic: HapticCue.error,
        );
      }
    } finally {
      _deletingIds.remove(comment.id);
    }
  }

  Future<void> _openThread(LightNovelComment comment) async {
    var changed = false;
    final result = await pushNovelPage<Object?>(
      context,
      OnlineReviewsPage(
        novel: widget.novel,
        account: widget.account,
        state: widget.state,
        repository: widget.repository,
        thread: comment,
        apiCall: widget.apiCall,
        onPosted: () => changed = true,
      ),
      slot: ('review-thread', widget.novel.id, comment.id),
      reduceMotion: widget.state.reduceMotion,
    );
    if (!mounted) return;
    if (result is int) {
      _activeFeed.removeLocalComment(result);
    } else if (changed && widget.feed == null) {
      unawaited(_activeFeed.load(refresh: true));
    }
  }

  Future<void> _loginToRead() async {
    if (widget.account.busy) return;
    await pushNovelPage<void>(
      context,
      OnlineAccountPage(
        account: widget.account,
        state: widget.state,
        repository: widget.repository,
      ),
      reduceMotion: widget.state.reduceMotion,
    );
    if (mounted && widget.account.authenticated) {
      await _activeFeed.load(refresh: true);
    }
  }

  Widget _buildHeaderControls(BuildContext context, LightNovelReviewFeed feed) {
    final threadRoot = widget.thread == null
        ? null
        : (feed.rootComment ?? widget.thread!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppText(
                widget.novel.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            GlassTextButton(
              key: const ValueKey('review-compose'),
              compact: true,
              onPressed: () => _compose(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ArchiveIcon(CupertinoIcons.pencil, size: 15),
                  const SizedBox(width: 6),
                  AppText(
                    widget.thread != null
                        ? '回复'
                        : _view == 'rating'
                        ? '写评价'
                        : '写评论',
                  ),
                ],
              ),
            ),
          ],
        ),
        if (widget.thread == null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassTextButton(
                    key: const ValueKey('review-tab-comments'),
                    compact: true,
                    selected: _view == '',
                    onPressed: () => _setView(''),
                    child: const AppText('评论'),
                  ),
                  const SizedBox(width: 8),
                  GlassTextButton(
                    key: const ValueKey('review-tab-rating'),
                    compact: true,
                    selected: _view == 'rating',
                    onPressed: () => _setView('rating'),
                    child: const AppText('评分评价'),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassTextButton(
                    key: const ValueKey('review-sort-hot'),
                    compact: true,
                    selected: _sort == 'hot',
                    onPressed: () => _setSort('hot'),
                    child: const AppText('热门'),
                  ),
                  const SizedBox(width: 8),
                  GlassTextButton(
                    key: const ValueKey('review-sort-latest'),
                    compact: true,
                    selected: _sort == 'latest',
                    onPressed: () => _setSort('latest'),
                    child: const AppText('最新'),
                  ),
                ],
              ),
            ],
          ),
          if (feed.totalCount > 0) ...[
            const SizedBox(height: 12),
            AppText(
              '共 ${feed.totalCount} 条${_view == 'rating' ? '评价' : '评论'}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ] else if (threadRoot != null) ...[
          const SizedBox(height: 16),
          _CommentCard(
            comment: threadRoot,
            emojis: _emojis,
            reduceMotion: widget.state.reduceMotion,
            isThreadView: true,
            codeLabel: '01 / ORIGINAL POST',
            onLike: () => _toggleLike(threadRoot),
            onDelete: threadRoot.isMine
                ? () => _deleteComment(threadRoot)
                : null,
          ),
          const SizedBox(height: 12),
          ArchiveCode(
            'REPLIES · ${feed.totalCount > 0 ? feed.totalCount : threadRoot.replyCount}',
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final feed = _activeFeed;
    return ArchiveFeaturePage(
      title: widget.thread == null ? '作品评论' : '评论详情',
      code: widget.thread == null
          ? 'REVIEW / ${ArchiveDesign.fileCode(widget.novel.id)}'
          : 'THREAD / ${widget.thread!.id}',
      actions: [
        GlassIconButton(
          icon: CupertinoIcons.refresh,
          label: '刷新评论',
          onPressed: () => feed.load(refresh: true),
        ),
      ],
      child: AnimatedBuilder(
        animation: feed,
        builder: (context, _) => feed.requiresLogin && feed.items.isEmpty
            ? ContentNotice(
                icon: CupertinoIcons.person_crop_circle,
                title: '登录后查看评论',
                message: '本机阅读记录和收藏不受影响。',
                actionLabel: '登录账号',
                onRetry: _loginToRead,
              )
            : LoadedContentSequence(
                generation: (
                  _view,
                  feed.commentSort,
                  feed.page,
                  feed.items.length,
                  feed.items.isEmpty ? null : feed.items.first.id,
                ),
                firstIndex: feed.firstIndex + 1,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth == 0 &&
                        notification.metrics.axis == Axis.vertical &&
                        notification.metrics.extentAfter < 600 &&
                        !feed.loading &&
                        feed.error == null &&
                        feed.hasMore) {
                      unawaited(feed.load());
                    }
                    return false;
                  },
                  child: ListView.builder(
                    padding: featurePadding(context),
                    itemCount: feed.items.length + 2,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _buildHeaderControls(context, feed);
                      }
                      if (index == feed.items.length + 1) {
                        return Column(
                          children: [
                            FeatureError(feed.error),
                            if (feed.loading)
                              Column(
                                children: [
                                  for (
                                    var item = 0;
                                    item < (feed.items.isEmpty ? 3 : 1);
                                    item++
                                  )
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: ReviewCardSkeleton(
                                        thread: widget.thread != null,
                                      ),
                                    ),
                                ],
                              ),
                            if (feed.error != null)
                              GlassTextButton(
                                onPressed: feed.requiresLogin
                                    ? _loginToRead
                                    : () => feed.load(),
                                child: AppText(
                                  feed.requiresLogin
                                      ? '登录后继续查看'
                                      : widget.thread == null
                                      ? '重试加载评论'
                                      : '重试加载回复',
                                ),
                              ),
                            if (!feed.loading &&
                                feed.error == null &&
                                feed.items.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 48,
                                ),
                                child: AppText(
                                  widget.thread == null
                                      ? (_view == 'rating'
                                            ? '还没有评分评价'
                                            : '还没有评论')
                                      : '暂时没有回复',
                                ),
                              ),
                            if (!feed.loading &&
                                feed.error == null &&
                                feed.hasMore)
                              GlassTextButton(
                                onPressed: () => feed.load(),
                                child: AppText(
                                  widget.thread == null ? '更多评论' : '更多回复',
                                ),
                              ),
                          ],
                        );
                      }
                      final comment = feed.items[index - 1];
                      return LoadedContentItem(
                        key: ValueKey('${_view}_${comment.identity}'),
                        index: index,
                        placeholder: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ReviewCardSkeleton(
                            thread: widget.thread != null,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _CommentCard(
                            key: ValueKey('review-card-${comment.identity}'),
                            comment: comment,
                            emojis: _emojis,
                            reduceMotion: widget.state.reduceMotion,
                            isThreadView: widget.thread != null,
                            codeLabel: widget.thread != null
                                ? '${(index + 1).toString().padLeft(2, '0')} / REPLY'
                                : null,
                            onTap: widget.thread != null
                                ? null
                                : () => _openThread(comment),
                            onLike: () => _toggleLike(comment),
                            onReply: widget.thread != null
                                ? () => _compose(replyTarget: comment)
                                : null,
                            onDelete: comment.isMine
                                ? () => _deleteComment(comment)
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  const _CommentCard({
    super.key,
    required this.comment,
    required this.emojis,
    required this.reduceMotion,
    required this.isThreadView,
    required this.onLike,
    this.codeLabel,
    this.onTap,
    this.onReply,
    this.onDelete,
  });

  final LightNovelComment comment;
  final LightNovelEmojiCatalog emojis;
  final bool reduceMotion;
  final bool isThreadView;
  final String? codeLabel;
  final VoidCallback? onTap;
  final VoidCallback onLike;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final displayName = comment.nickname.isNotEmpty
        ? comment.nickname
        : '书友 ${comment.userId > 0 ? comment.userId : comment.id}';
    final byline = comment.dateText.isNotEmpty
        ? '$displayName  ·  ${comment.dateText}'
        : displayName;

    return ContentPanel(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (codeLabel != null) ...[
            ArchiveCode(codeLabel!),
            const SizedBox(height: 10),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppText(
                displayName,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (comment.levelName.isNotEmpty) ArchiveCode(comment.levelName),
              if (comment.replyToUser.isNotEmpty)
                AppText(
                  '回复 @${comment.replyToUser}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (comment.ratingStars > 0) ...[
            const SizedBox(height: 6),
            _StarRatingRow(stars: comment.ratingStars),
          ],
          const SizedBox(height: 10),
          _CommentBody(
            comment: comment,
            emojis: emojis,
            byline: byline,
            reduceMotion: reduceMotion,
          ),
          if (comment.imageUrls.isNotEmpty) ...[
            const SizedBox(height: 10),
            _CommentImageStrip(
              urls: comment.imageUrls,
              reduceMotion: reduceMotion,
            ),
          ],
          if (!isThreadView && comment.replyPreview.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: .045),
                borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < comment.replyPreview.length && i < 3; i++)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                      child: AppText(
                        _formatPreviewLine(comment.replyPreview[i]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              GlassTextButton(
                key: ValueKey('comment-like-${comment.id}'),
                compact: true,
                selected: comment.liked,
                onPressed: onLike,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ArchiveIcon(
                      comment.liked
                          ? CupertinoIcons.hand_thumbsup_fill
                          : CupertinoIcons.hand_thumbsup,
                      size: 14,
                    ),
                    const SizedBox(width: 5),
                    AppText('${comment.likeCount}'),
                  ],
                ),
              ),
              if (onReply != null) ...[
                const SizedBox(width: 8),
                GlassTextButton(
                  key: ValueKey('comment-reply-${comment.id}'),
                  compact: true,
                  onPressed: onReply,
                  child: const AppText('回复'),
                ),
              ],
              if (!isThreadView) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: AppText(
                    '${comment.replyCount} 条回复 · 查看对话',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              if (onDelete != null)
                GlassIconButton(
                  key: ValueKey('comment-delete-${comment.id}'),
                  icon: CupertinoIcons.trash,
                  label: '删除评论',
                  onPressed: onDelete,
                ),
              if (!isThreadView)
                const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
            ],
          ),
        ],
      ),
    );
  }

  String _formatPreviewLine(LightNovelComment reply) {
    final author = reply.nickname.isNotEmpty ? reply.nickname : '书友';
    final target = reply.replyToUser.isNotEmpty
        ? ' 回复 @${reply.replyToUser}'
        : '';
    final body = emojis.formatText(reply.content).trim();
    return '$author$target：$body';
  }
}

class _StarRatingRow extends StatelessWidget {
  const _StarRatingRow({required this.stars});
  final int stars;

  @override
  Widget build(BuildContext context) {
    final activeColor = Colors.amber.shade700;
    final inactiveColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Icon(
              i <= stars ? CupertinoIcons.star_fill : CupertinoIcons.star,
              size: 14,
              color: i <= stars ? activeColor : inactiveColor,
            ),
          ),
        const SizedBox(width: 6),
        AppText(
          '$stars 星',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: activeColor,
          ),
        ),
      ],
    );
  }
}

class _CommentBody extends StatelessWidget {
  const _CommentBody({
    required this.comment,
    required this.emojis,
    required this.byline,
    required this.reduceMotion,
  });

  final LightNovelComment comment;
  final LightNovelEmojiCatalog emojis;
  final String byline;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final segments = emojis.parseSegments(comment.content);
    final hasStickers = segments.any((segment) => segment.isSticker);
    if (!hasStickers) {
      final resolved = segments.isEmpty
          ? comment.content
          : segments.map((segment) => segment.text).join();
      return ReviewContent(
        content: resolved,
        byline: byline,
        reduceMotion: reduceMotion,
      );
    }
    return _StickerCommentBody(
      segments: segments,
      plainText: emojis.formatText(comment.content),
      byline: byline,
    );
  }
}

class _StickerCommentBody extends StatefulWidget {
  const _StickerCommentBody({
    required this.segments,
    required this.plainText,
    required this.byline,
  });

  final List<LightNovelEmojiToken> segments;
  final String plainText;
  final String byline;

  @override
  State<_StickerCommentBody> createState() => _StickerCommentBodyState();
}

class _StickerCommentBodyState extends State<_StickerCommentBody> {
  final Map<Uri, TapGestureRecognizer> _recognizers = {};
  late List<({LightNovelEmojiToken token, ReviewDocument? doc})> _parsed;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(_StickerCommentBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.plainText != widget.plainText ||
        oldWidget.segments.length != widget.segments.length) {
      _rebuild();
    }
  }

  void _rebuild() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _parsed = [
      for (final segment in widget.segments)
        if (segment.isSticker)
          (token: segment, doc: null)
        else
          (token: segment, doc: ReviewDocument.parse(segment.text)),
    ];
    for (final entry in _parsed) {
      final doc = entry.doc;
      if (doc == null) continue;
      for (final uri in doc.links) {
        _recognizers.putIfAbsent(
          uri,
          () => TapGestureRecognizer()..onTap = () => unawaited(_open(uri)),
        );
      }
    }
  }

  Future<void> _open(Uri uri) async {
    AppHaptics.play(context, HapticCue.action);
    try {
      if ((defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.android) &&
          await launchUrl(
            uri,
            mode: LaunchMode.externalNonBrowserApplication,
          )) {
        return;
      }
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('No link handler');
      }
    } catch (_) {
      if (mounted) {
        showNovelFeedback(context, '暂时无法打开链接', haptic: HapticCue.error);
      }
    }
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.plainText));
      if (mounted) {
        showNovelFeedback(context, '评论已复制', haptic: HapticCue.success);
      }
    } catch (_) {
      if (mounted) {
        showNovelFeedback(context, '复制未完成，请重试', haptic: HapticCue.error);
      }
    }
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final span = TextSpan(
      style: DefaultTextStyle.of(
        context,
      ).style.merge(const TextStyle(fontSize: 14, height: 1.8)),
      children: [
        for (final entry in _parsed)
          if (entry.token.isSticker)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _InlineSticker(
                url: entry.token.stickerUrl!,
                code: entry.token.code,
              ),
            )
          else if (entry.doc != null)
            for (final part in entry.doc!.parts)
              TextSpan(
                text: part.text,
                recognizer: _recognizers[part.link],
                style: part.link == null
                    ? null
                    : TextStyle(
                        color: colors.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: colors.primary.withValues(alpha: .5),
                      ),
              ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ReadOnlyText.rich(span, textKey: const ValueKey('review-prose')),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: AppText(
                widget.byline,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            GlassIconButton(
              key: const ValueKey('review-copy-text'),
              haptic: null,
              icon: CupertinoIcons.doc_on_doc,
              label: '复制评论',
              onPressed: _copy,
            ),
          ],
        ),
      ],
    );
  }
}

class _InlineSticker extends StatelessWidget {
  const _InlineSticker({required this.url, required this.code});
  final String url;
  final String code;

  @override
  Widget build(BuildContext context) {
    final cached = OnlineMedia.peek(url);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: FutureBuilder<Uint8List>(
        future: cached != null ? null : OnlineMedia.illustration(url),
        initialData: cached,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            return Text(
              code,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            );
          }
          return Image.memory(
            bytes,
            width: 24,
            height: 24,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Text(code),
          );
        },
      ),
    );
  }
}

class _CommentImageStrip extends StatelessWidget {
  const _CommentImageStrip({required this.urls, required this.reduceMotion});
  final List<String> urls;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (var i = 0; i < urls.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          _CommentImageThumb(
            url: urls[i],
            onTap: () => pushNovelPage<void>(
              context,
              ReaderIllustrationGallery(
                urls: urls,
                initialUrl: urls[i],
                title: '评论附图',
                fileNamePrefix: 'comment-image',
                cache: ReaderIllustrationCache(
                  request: (url) => OnlineMedia.illustration(url),
                ),
              ),
              reduceMotion: reduceMotion,
            ),
          ),
        ],
      ],
    ),
  );
}

class _CommentImageThumb extends StatelessWidget {
  const _CommentImageThumb({required this.url, required this.onTap});
  final String url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cached = OnlineMedia.peek(url);
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
        child: SizedBox(
          width: 72,
          height: 72,
          child: FutureBuilder<Uint8List>(
            future: cached != null ? null : OnlineMedia.illustration(url),
            initialData: cached,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) {
                return ColoredBox(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: .06),
                  child: const Center(
                    child: ArchiveIcon(CupertinoIcons.photo, size: 22),
                  ),
                );
              }
              return Image.memory(
                bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Center(
                  child: ArchiveIcon(CupertinoIcons.photo, size: 22),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class ReviewCardSkeleton extends StatelessWidget {
  const ReviewCardSkeleton({super.key, this.thread = false});
  final bool thread;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ContentPanel(
      child: SizedBox(
        height:
            (thread ? 174 : 104) *
            (MediaQuery.textScalerOf(context).scale(14) / 14),
        width: double.infinity,
        child: LoadingSkeleton(
          layout: thread ? SkeletonLayout.reviewThread : SkeletonLayout.review,
          label: thread ? '正在读取正文与回复' : '正在读取评论',
        ),
      ),
    ),
  );
}

class ReviewComposerPage extends StatefulWidget {
  const ReviewComposerPage({
    super.key,
    required this.novel,
    required this.account,
    required this.reduceMotion,
    this.thread,
    this.initialRatingStars = 0,
    this.view = '',
    this.replyTarget,
  });
  final Novel novel;
  final LightNovelAccount account;
  final bool reduceMotion;
  final LightNovelComment? thread;
  final int initialRatingStars;
  final String view;
  final LightNovelComment? replyTarget;

  @override
  State<ReviewComposerPage> createState() => _ReviewComposerPageState();
}

class _ReviewComposerPageState extends State<ReviewComposerPage> {
  final _body = TextEditingController();
  SharedPreferences? _preferences;
  Timer? _saveDelay;
  Future<void> _writes = Future.value();
  bool _busy = false, _loaded = false, _posted = false;
  late int _ratingStars = widget.initialRatingStars.clamp(0, 5);
  String? _error;

  String get _draftKey =>
      'lightnovel_review_draft_${widget.account.profile?.uid ?? 0}_${widget.novel.id}_${widget.thread?.id ?? 0}';
  late final String _resolvedDraftKey = _draftKey;

  @override
  void initState() {
    super.initState();
    _body.addListener(_edited);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _preferences = prefs;
      _body.text = prefs.getString(_resolvedDraftKey) ?? '';
    } catch (_) {
      _error = '草稿读取失败，当前编辑内容请先保留';
    }
    if (mounted) setState(() => _loaded = true);
  }

  void _edited() {
    if (!_loaded || _posted) return;
    _saveDelay?.cancel();
    _saveDelay = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() {
    _saveDelay?.cancel();
    final body = _body.text, prefs = _preferences;
    if (prefs == null || _posted) return _writes;
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) async {
          if (!await prefs.setString(_resolvedDraftKey, body)) {
            throw StateError('Draft write failed');
          }
        })
        .catchError((Object _) {
          if (mounted) setState(() => _error = '草稿保存失败，请保留当前内容后重试');
        });
  }

  Future<void> _post() async {
    if (_busy || !_loaded || _posted) return;
    final content = _body.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '请输入评论内容');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    await _save();
    try {
      final LightNovelComment? created;
      if (widget.thread case final thread?) {
        created = await widget.account.replyComment(
          bookId: widget.novel.id,
          rootCommentId: thread.id,
          replyCommentId: widget.replyTarget?.id ?? thread.id,
          content: content,
          view: widget.view,
        );
      } else {
        created = await widget.account.postComment(
          bookId: widget.novel.id,
          content: content,
          ratingStars: _ratingStars,
          view: _ratingStars > 0 ? 'rating' : widget.view,
        );
      }
      _posted = true;
      await _writes;
      try {
        await _preferences?.remove(_resolvedDraftKey);
      } catch (_) {
        /* A successful server post is not retried for a draft cleanup error. */
      }
      if (mounted) {
        setState(() => _busy = false);
        Navigator.pop(context, created ?? true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _describeReviewError(widget.account, error);
        });
      }
    }
  }

  @override
  void dispose() {
    _saveDelay?.cancel();
    if (!_posted) unawaited(_save());
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targetLabel = widget.replyTarget != null
        ? '回复 @${widget.replyTarget!.nickname.isNotEmpty ? widget.replyTarget!.nickname : '书友'}'
        : widget.thread != null
        ? '回复 ${widget.thread!.nickname.isNotEmpty ? widget.thread!.nickname : '原评论'}'
        : widget.novel.title;
    final showStarSelector =
        widget.thread == null && (widget.view == 'rating' || _ratingStars > 0);
    return PopScope(
      canPop: !_busy,
      child: ArchiveFeaturePage(
        title: widget.thread == null ? '写评论' : '回复评论',
        code: 'REVIEW / COMPOSE',
        canPop: !_busy,
        actions: [
          GlassTextButton(
            key: const ValueKey('review-submit'),
            compact: true,
            onPressed: !_loaded || _busy || _posted ? null : _post,
            child: AppText(
              _posted
                  ? '已发表'
                  : _busy
                  ? '正在发表'
                  : '发表',
            ),
          ),
        ],
        child: ListView(
          padding: featurePadding(context),
          children: [
            AppText(
              targetLabel,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            AppText(
              '草稿自动保存 · 支持 emoji 与完整 UTF-8',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (!_loaded)
              const SizedBox(
                height: 200,
                child: LoadingSkeleton(layout: SkeletonLayout.reader),
              )
            else
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.thread == null) ...[
                      if (showStarSelector)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Wrap(
                            spacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              AppText(
                                '评分',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 8),
                              for (var star = 1; star <= 5; star++)
                                IconButton(
                                  key: ValueKey('review-star-$star'),
                                  tooltip: '$star 星',
                                  onPressed: _busy
                                      ? null
                                      : () {
                                          AppHaptics.play(
                                            context,
                                            HapticCue.selection,
                                          );
                                          setState(() {
                                            _ratingStars = _ratingStars == star
                                                ? 0
                                                : star;
                                          });
                                        },
                                  icon: Icon(
                                    star <= _ratingStars
                                        ? CupertinoIcons.star_fill
                                        : CupertinoIcons.star,
                                    size: 22,
                                    color: star <= _ratingStars
                                        ? Colors.amber.shade700
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              if (_ratingStars > 0)
                                AppText(
                                  '$_ratingStars 星',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.amber.shade700,
                                  ),
                                ),
                            ],
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GlassTextButton(
                            key: const ValueKey('review-add-rating'),
                            compact: true,
                            onPressed: _busy
                                ? null
                                : () => setState(() => _ratingStars = 5),
                            child: const AppText('添加星级评分'),
                          ),
                        ),
                    ],
                    TextField(
                      key: const ValueKey('review-body'),
                      onTap: () =>
                          AppHaptics.play(context, HapticCue.selection),
                      onTapAlwaysCalled: true,
                      controller: _body,
                      enabled: !_busy,
                      minLines: 8,
                      maxLines: 20,
                      maxLength: 4000,
                      style: const TextStyle(fontSize: 14, height: 1.8),
                      decoration: InputDecoration(
                        hintText: appText(context, '写下你的想法…'),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                    ),
                    FeatureError(_error),
                    if (_busy)
                      const SizedBox(
                        height: 64,
                        child: LoadingSkeleton(
                          layout: SkeletonLayout.actions,
                          label: '正在发表',
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
