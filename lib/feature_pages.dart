import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'library_workspace.dart';
import 'lightnovel/lightnovel_account.dart';
import 'lightnovel/lightnovel_client.dart';
import 'novel_feed_controller.dart';
import 'online_component.dart';
import 'online_features.dart';
import 'pages.dart' show DiscoverPage, openDetail;
import 'publication_catalog.dart';

Future<bool> confirmNovelAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool reduceMotion = false,
}) async =>
    await showJellySheet<bool>(
      context: context,
      reduceMotion: reduceMotion,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText(
              title,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            AppText(message),
            const SizedBox(height: 24),
            GlassTextButton(
              onPressed: () => Navigator.pop(sheet, true),
              haptic: HapticCue.warning,
              child: AppText(confirmLabel),
            ),
            const SizedBox(height: 8),
            GlassTextButton(
              onPressed: () => Navigator.pop(sheet, false),
              child: const AppText('取消'),
            ),
          ],
        ),
      ),
    ) ==
    true;

class ArchiveFeaturePage extends StatelessWidget {
  const ArchiveFeaturePage({
    super.key,
    required this.title,
    required this.code,
    required this.child,
    this.actions = const [],
    this.canPop = true,
  });
  final String title, code;
  final Widget child;
  final List<Widget> actions;
  final bool canPop;
  @override
  Widget build(BuildContext context) => LibraryWorkspace(
    child: Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: ArchiveHeaderBar(
            leading: GlassIconButton(
              icon: CupertinoIcons.back,
              label: '返回',
              onPressed: canPop ? () => Navigator.pop(context) : null,
            ),
            title: ArchiveRouteTitle(title: title, code: code),
            actions: actions,
          ),
          body: child,
        ),
      ),
    ),
  );
}

EdgeInsets featurePadding(BuildContext context) => EdgeInsets.fromLTRB(
  24,
  MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight + 20,
  24,
  MediaQuery.paddingOf(context).bottom + 32,
);

class FeatureEntry extends StatelessWidget {
  const FeatureEntry({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ContentPanel(
    onTap: onTap,
    child: ArchivePart(
      start: .18,
      end: .84,
      travel: const Offset(0, 6),
      child: Row(
        children: [
          ArchiveIcon(icon, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 5),
                  AppText(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
        ],
      ),
    ),
  );
}

class FeatureError extends StatelessWidget {
  const FeatureError(this.text, {super.key});
  final String? text;
  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Semantics(
            liveRegion: true,
            child: AppText(
              text!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        );
}

String _describeOnlineError(LightNovelAccount? account, Object error) {
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

class OnlineAccountPage extends StatefulWidget {
  const OnlineAccountPage({
    super.key,
    required this.account,
    required this.state,
    required this.repository,
  });
  final LightNovelAccount account;
  final LibraryState state;
  final NovelRepository repository;
  @override
  State<OnlineAccountPage> createState() => _OnlineAccountPageState();
}

class _OnlineAccountPageState extends State<OnlineAccountPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.account.authenticated) {
        unawaited(widget.account.initialize());
      }
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work, String success) async {
    if (widget.account.busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await work();
      if (mounted) showNovelFeedback(context, success);
    } catch (_) {
      /* The account's live region displays the concrete failure. */
    }
  }

  Future<void> _login() async {
    final account = widget.account;
    if (account.busy) return;
    final revision = account.sessionRevision;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await account.login(_username.text, _password.text);
      if (mounted) showNovelFeedback(context, '登录成功');
    } catch (_) {
      // The account's live region displays the concrete failure.
    } finally {
      if (mounted) {
        // Finish before clearing: the system must see the submitted password.
        // A successful API login still counts if only profile loading failed.
        TextInput.finishAutofillContext(
          shouldSave:
              account.authenticated && account.sessionRevision != revision,
        );
        _password.clear();
      }
    }
  }

  Future<void> _logout() async {
    final confirmed = await confirmNovelAction(
      context,
      title: '退出账号？',
      message: '仅退出云端账号，本机书架、阅读进度、书签与离线章节均保留。',
      confirmLabel: '退出账号',
      reduceMotion: widget.state.reduceMotion,
    );
    if (confirmed) await _run(widget.account.logout, '已退出账号');
  }

  @override
  Widget build(BuildContext context) => AutofillGroup(
    // Leaving/cancelling the form must not offer to save unverified input.
    onDisposeAction: AutofillContextAction.cancel,
    child: AnimatedBuilder(
      animation: widget.account,
      builder: (context, _) {
        final account = widget.account;
        final profile = account.profile;
        return ArchiveFeaturePage(
          title: '轻之国度账号',
          code: 'ACCOUNT / LIGHTNOVEL',
          child: LoadedContentSequence(
            generation: (account.authenticated, profile?.uid),
            child: ListView(
              key: ValueKey(account.authenticated),
              padding: featurePadding(context),
              children: [
                LoadedContentItem(
                  index: 0,
                  child: AppText(
                    account.authenticated
                        ? profile?.displayName ?? '已登录'
                        : '连接轻之国度',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                AppText(
                  account.authenticated
                      ? '登录后自动同步云书架与进度，本机阅读记录与本地书籍保留。'
                      : '使用轻之国度账号登录。未登录时仍可浏览榜单、搜索、收藏到本机和离线阅读。',
                ),
                const SizedBox(height: 24),
                if (!account.authenticated)
                  ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const ValueKey('account-username'),
                          onTap: () =>
                              AppHaptics.play(context, HapticCue.selection),
                          onTapAlwaysCalled: true,
                          controller: _username,
                          enabled: !account.busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                          maxLength: 254,
                          decoration: InputDecoration(
                            labelText: appText(context, '用户名 / 邮箱'),
                            hintText: appText(context, '请输入用户名或邮箱'),
                            counterText: '',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('account-password'),
                          onTap: () =>
                              AppHaptics.play(context, HapticCue.selection),
                          onTapAlwaysCalled: true,
                          controller: _password,
                          enabled: !account.busy,
                          obscureText: _obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.visiblePassword,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.password],
                          smartDashesType: SmartDashesType.disabled,
                          smartQuotesType: SmartQuotesType.disabled,
                          maxLength: 128,
                          onSubmitted: (_) => _login(),
                          decoration: InputDecoration(
                            labelText: appText(context, '密码'),
                            hintText: appText(context, '请输入密码'),
                            counterText: '',
                            suffixIcon: IconButton(
                              tooltip: _obscure ? '显示密码' : '隐藏密码',
                              icon: ArchiveIcon(
                                _obscure
                                    ? CupertinoIcons.eye
                                    : CupertinoIcons.eye_slash,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        GlassTextButton(
                          key: const ValueKey('account-login'),
                          onPressed: account.busy ? null : _login,
                          child: const AppText('登录'),
                        ),
                      ],
                    ),
                  )
                else ...[
                  LoadedContentItem(
                    index: 1,
                    child: ContentPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (profile == null && account.busy)
                            const SizedBox(
                              height: 72,
                              child: LoadingSkeleton(
                                layout: SkeletonLayout.actions,
                              ),
                            )
                          else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (account.avatar != null) ...[
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: SizedBox(
                                      width: 52,
                                      height: 52,
                                      child: Image.memory(
                                        account.avatar!,
                                        fit: BoxFit.cover,
                                        cacheWidth:
                                            (52 *
                                                    MediaQuery.devicePixelRatioOf(
                                                      context,
                                                    ))
                                                .ceil(),
                                        errorBuilder: (_, _, _) =>
                                            const ArchiveIcon(
                                              CupertinoIcons.person_crop_circle,
                                              size: 36,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                ],
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ArchiveCode(
                                        profile == null
                                            ? 'SESSION / READY'
                                            : 'UID / ${profile.uid}',
                                      ),
                                      const SizedBox(height: 10),
                                      if (profile != null) ...[
                                        AppText(
                                          profile.displayName,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        AppText(
                                          profile.levelName.isNotEmpty
                                              ? 'LV.${profile.level} ${profile.levelName}'
                                              : 'LV.${profile.level}',
                                        ),
                                        const SizedBox(height: 6),
                                        AppText(
                                          '${profile.coin} 轻币 · ${profile.exp} 经验 · ${profile.followers} 粉丝',
                                        ),
                                        if (profile.sign.isNotEmpty) ...[
                                          const SizedBox(height: 8),
                                          AppText(
                                            profile.sign,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          const SizedBox(height: 12),
                          GlassTextButton(
                            onPressed: account.busy
                                ? null
                                : () => _run(account.refreshProfile, '账号已更新'),
                            child: const AppText('刷新资料'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  LoadedContentItem(
                    index: 2,
                    child: FeatureEntry(
                      key: const ValueKey('account-cloud'),
                      title: '云书架',
                      subtitle: '收藏自动同步，查看云端书目',
                      icon: CupertinoIcons.cloud,
                      onTap: account.busy
                          ? null
                          : () => pushNovelPage<void>(
                              context,
                              CloudBookshelfPage(
                                account: account,
                                state: widget.state,
                                repository: widget.repository,
                              ),
                              reduceMotion: widget.state.reduceMotion,
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  GlassTextButton(
                    key: const ValueKey('account-logout'),
                    onPressed: account.busy ? null : _logout,
                    child: const AppText('退出账号'),
                  ),
                ],
                if (account.busy) ...[
                  const SizedBox(height: 20),
                  const InlineSkeleton(label: '正在处理账号操作'),
                  const SizedBox(height: 10),
                  AppText(account.operation ?? ''),
                ],
                FeatureError(account.error),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class CloudBookshelfPage extends StatefulWidget {
  const CloudBookshelfPage({
    super.key,
    required this.account,
    required this.state,
    required this.repository,
  });
  final LightNovelAccount account;
  final LibraryState state;
  final NovelRepository repository;
  @override
  State<CloudBookshelfPage> createState() => _CloudBookshelfPageState();
}

class _CloudBookshelfPageState extends State<CloudBookshelfPage> {
  String? _localError;
  bool _merging = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    if (widget.account.busy) return;
    try {
      final sync = OnlineFeaturesScope.maybeOf(context)?.shelfSync;
      if (sync != null) {
        await sync.synchronize();
        return;
      }
      await widget.account.refreshCloud();
    } catch (_) {}
  }

  Future<void> _merge() async {
    if (_merging || widget.account.busy) return;
    final confirmed = await confirmNovelAction(
      context,
      title: '合并云书架到本机？',
      message: '添加云端收藏。本机已有书籍、进度、书签和缓存保持不变。',
      confirmLabel: '合并收藏',
      reduceMotion: widget.state.reduceMotion,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _merging = true;
      _localError = null;
    });
    try {
      final count = await widget.account.mergeCloudToLocal(widget.state);
      if (mounted) showNovelFeedback(context, '已添加 $count 本云端收藏到本机');
    } catch (error) {
      if (mounted) {
        setState(
          () => _localError = _describeOnlineError(widget.account, error),
        );
      }
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  Future<void> _upload() async {
    if (_merging || widget.account.busy) return;
    final confirmed = await confirmNovelAction(
      context,
      title: '合并本机收藏到云端？',
      message: '仅上传云端没有的本机收藏。不会删除云端书籍，也不上传正文或阅读记录。',
      confirmLabel: '合并到云端',
      reduceMotion: widget.state.reduceMotion,
    );
    if (!confirmed || !mounted) return;
    try {
      final result = await widget.account.uploadMissing(widget.state.shelf);
      if (mounted) {
        showNovelFeedback(
          context,
          result.remaining.isEmpty
              ? '云书架已合并 · 新增 ${result.uploaded.length} 本'
              : '已完成 ${result.uploaded.length} 本，剩余 ${result.remaining.length} 本可重试',
        );
      }
    } catch (_) {}
  }

  Future<void> _remove(LightNovelCloudBook book) async {
    if (widget.account.busy || _merging) return;
    final confirmed = await confirmNovelAction(
      context,
      title: '移出云书架？',
      message:
          '「${book.title.isEmpty ? '书籍 ${book.bookId}' : book.title}」的本机收藏、进度及缓存仍保留。',
      confirmLabel: '移出云书架',
      reduceMotion: widget.state.reduceMotion,
    );
    if (!confirmed || !mounted) return;
    try {
      await widget.account.removeCloud(book.bookId);
    } catch (_) {}
  }

  void _open(LightNovelCloudBook book) {
    final novel =
        widget.state.cachedNovel(book.bookId) ??
        Novel(
          id: book.bookId,
          title: book.title.isEmpty ? '书籍 ${book.bookId}' : book.title,
          author: book.author,
          genre: '轻小说',
          summary: '',
          colors: const [Color(0xFF202020), Color(0xFF333333)],
          coverUrl: book.coverUrl.isEmpty ? null : book.coverUrl,
          lastUpdate: book.updatedAt.isEmpty ? null : book.updatedAt,
        );
    openDetail(context, novel, widget.state, widget.repository);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.account,
      widget.state,
      ?OnlineFeaturesScope.maybeOf(context)?.shelfSync,
    ]),
    builder: (context, _) {
      final account = widget.account;
      final books = account.cloudBooks;
      final busy = account.busy || _merging;
      final sync = OnlineFeaturesScope.maybeOf(context)?.shelfSync;
      return ArchiveFeaturePage(
        title: '云书架',
        code: 'CLOUD / COLLECTION',
        actions: [
          GlassIconButton(
            icon: CupertinoIcons.refresh,
            label: '刷新云书架',
            onPressed: busy ? null : _refresh,
          ),
        ],
        child: LoadedContentSequence(
          generation: books,
          child: ListView.builder(
            padding: featurePadding(context),
            itemCount: 1 + (books?.length ?? 0),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    sectionHeader(
                      context,
                      '云端收藏',
                      books == null ? '' : '${books.length} 本',
                    ),
                    const SizedBox(height: 12),
                    AppText(
                      sync == null
                          ? '两端只合并收藏，阅读进度与本地文件保留。'
                          : sync.syncing
                          ? '正在自动同步收藏'
                          : sync.error != null
                          ? '自动同步待重试 · ${sync.error}'
                          : '收藏自动同步 · 联网或回到前台时自动更新',
                    ),
                    const SizedBox(height: 16),
                    if (sync == null)
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          GlassTextButton(
                            key: const ValueKey('cloud-download'),
                            onPressed: busy || books == null ? null : _merge,
                            child: const AppText('合并到本机'),
                          ),
                          GlassTextButton(
                            key: const ValueKey('cloud-upload'),
                            onPressed: busy || books == null ? null : _upload,
                            child: const AppText('合并到云端'),
                          ),
                        ],
                      ),
                    FeatureError(_localError ?? account.error),
                    if (busy)
                      const SizedBox(
                        height: 72,
                        child: LoadingSkeleton(layout: SkeletonLayout.actions),
                      ),
                    if (books?.isEmpty == true)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 60),
                        child: Center(child: AppText('云书架还没有收藏')),
                      ),
                    const SizedBox(height: 20),
                  ],
                );
              }
              final book = books![index - 1];
              final updateLabel = book.unreadChapterCount > 0
                  ? '有 ${book.unreadChapterCount} 章未读更新'
                  : book.hasUpdate
                  ? '有更新'
                  : '';
              final detailLine = [
                if (book.author.isNotEmpty) book.author,
                if (updateLabel.isNotEmpty) updateLabel,
              ].join(' · ');
              final shelfTag = widget.state.contains(book.bookId)
                  ? 'LOCAL + CLOUD'
                  : 'CLOUD';
              return LoadedContentItem(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ContentPanel(
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _open(book),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AppText(
                                  book.title.isEmpty
                                      ? '书籍 ${book.bookId}'
                                      : book.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (detailLine.isNotEmpty) ...[
                                  const SizedBox(height: 7),
                                  AppText(
                                    detailLine,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                ArchiveCode(
                                  book.updatedAt.isNotEmpty
                                      ? '${book.updatedAt}  /  $shelfTag'
                                      : shelfTag,
                                ),
                              ],
                            ),
                          ),
                        ),
                        GlassIconButton(
                          icon: CupertinoIcons.minus_circle,
                          label: '移出云书架 ${book.bookId}',
                          onPressed: busy ? null : () => _remove(book),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

class PublicationLibraryPage extends StatefulWidget {
  const PublicationLibraryPage({
    super.key,
    required this.catalog,
    required this.repository,
    required this.state,
    this.account,
  });
  final PublicationCatalog catalog;
  final NovelRepository repository;
  final LibraryState state;
  final LightNovelAccount? account;
  @override
  State<PublicationLibraryPage> createState() => _PublicationLibraryPageState();
}

class _PublicationLibraryPageState extends State<PublicationLibraryPage> {
  List<PublicationLibrary> _libraries = const [];
  PublicationLibrary? _selected;
  NovelFeedController? _feed;
  String? _error;
  late int _accountRevision;
  late bool _authenticated;
  bool _accountPageOpen = false;
  @override
  void initState() {
    super.initState();
    _accountRevision = widget.account?.sessionRevision ?? 0;
    _authenticated = widget.account?.authenticated ?? false;
    widget.account?.addListener(_accountChanged);
    unawaited(_load());
  }

  void _accountChanged() {
    final account = widget.account;
    if (account == null || !mounted || _accountPageOpen || account.busy) return;
    if (_accountRevision == account.sessionRevision &&
        _authenticated == account.authenticated) {
      return;
    }
    _accountRevision = account.sessionRevision;
    _authenticated = account.authenticated;
    final library = _selected;
    if (library != null) _select(library, force: true);
  }

  @override
  void didUpdateWidget(PublicationLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account) {
      oldWidget.account?.removeListener(_accountChanged);
      _accountRevision = widget.account?.sessionRevision ?? 0;
      _authenticated = widget.account?.authenticated ?? false;
      widget.account?.addListener(_accountChanged);
      _accountChanged();
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      if (widget.account != null && !widget.account!.authenticated) {
        await widget.account!.initialize();
      }
      final libraries = await widget.catalog.publicationLibraries(
        refresh: true,
      );
      if (mounted) {
        if (libraries.isEmpty) {
          setState(() => _error = '暂无可用的频道分类');
          return;
        }
        _libraries = libraries;
        _select(libraries.first);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _describeOnlineError(widget.account, error));
      }
    }
  }

  void _select(PublicationLibrary library, {bool force = false}) {
    if (!force && _selected?.id == library.id) return;
    _feed?.dispose();
    setState(() {
      _selected = library;
      _feed = NovelFeedController(
        PublicationNovelRepository(widget.repository, widget.catalog, library),
        initialItems: 60,
      );
    });
    if (force) {
      unawaited(_feed!.refresh());
    } else {
      _feed!.loadInitial();
    }
  }

  Future<void> _choose(BuildContext anchor) async {
    final selected = await showGlassMenu<PublicationLibrary>(
      context: anchor,
      reduceMotion: widget.state.reduceMotion,
      builder: (menuContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(menuContext).height * .62,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, library) in _libraries.indexed)
                GlassMenuItem(
                  order: index,
                  label: library.name,
                  selected: _selected?.id == library.id,
                  onPressed: () => Navigator.pop(menuContext, library),
                ),
            ],
          ),
        ),
      ),
    );
    if (mounted && selected != null) _select(selected);
  }

  Future<void> _loginForLibrary() async {
    final account = widget.account;
    if (account == null || _accountPageOpen) return;
    _accountPageOpen = true;
    try {
      await pushNovelPage<void>(
        context,
        OnlineAccountPage(
          account: account,
          state: widget.state,
          repository: widget.repository,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    } finally {
      if (mounted) {
        setState(() => _accountPageOpen = false);
        _accountChanged();
      }
    }
  }

  Widget _catalogBody(BuildContext context) {
    final account = widget.account;
    if (account != null &&
        account.busy &&
        (_accountRevision != account.sessionRevision ||
            _authenticated != account.authenticated)) {
      return const LibrarySkeleton();
    }
    final failure = _feed?.error;
    if (failure is FormatException && _feed!.items.isEmpty) {
      return ContentNotice(
        icon: CupertinoIcons.wifi_exclamationmark,
        title: '频道分类暂时不可用',
        message: failure.message,
        onRetry: _feed!.retry,
      );
    }
    if (failure is OnlineAuthenticationRequired && widget.account != null) {
      return ContentNotice(
        icon: widget.account!.authenticated
            ? CupertinoIcons.arrow_clockwise
            : CupertinoIcons.person_crop_circle,
        title: widget.account!.authenticated ? '频道暂未读取成功' : '此频道需要登录账号',
        message: widget.account!.authenticated
            ? '账号连接正常，频道服务暂未返回书目。请稍后重新加载。'
            : '登录后可继续浏览此频道。排行榜和搜索仍可直接使用。',
        actionLabel: widget.account!.authenticated ? '重新加载' : '登录账号',
        onRetry: widget.account!.authenticated
            ? () => _select(_selected!, force: true)
            : _loginForLibrary,
      );
    }
    return DiscoverPage(
      key: ValueKey(_selected!.id),
      books: const [],
      state: widget.state,
      repository: widget.repository,
      onSearch: () {},
      showHeader: false,
      feed: _feed,
      categoryTitle: _selected!.name,
      onChooseCategory: _choose,
    );
  }

  @override
  void dispose() {
    widget.account?.removeListener(_accountChanged);
    _feed?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '频道分类',
    code: 'CATALOG / CHANNELS',
    child: _selected == null
        ? (_error != null
              ? ContentNotice(
                  icon: CupertinoIcons.wifi_exclamationmark,
                  title: '频道分类加载失败',
                  message: _error!,
                  onRetry: _load,
                )
              : const LibrarySkeleton())
        : AnimatedBuilder(
            animation: _feed!,
            builder: (context, _) => _catalogBody(context),
          ),
  );
}
