import 'dart:async';
import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _lightNovelDynamicQueryParams = {'m', 't'};

/// Whether [host] belongs to LightNovel.fun or one of its subdomains.
bool isLightNovelImageHost(String host) {
  final lower = host.toLowerCase();
  return lower == 'lightnovel.fun' || lower.endsWith('.lightnovel.fun');
}

/// Whether [host] is a public external hostname or public IP (rejecting empty,
/// single-label hosts, local/internal domains, loopback, link-local,
/// unspecified, CGNAT, and RFC1918/ULA private addresses).
bool isPublicExternalHost(String host) {
  var normalized = host.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  if (normalized.startsWith('[') && normalized.endsWith(']')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  if (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.isEmpty) return false;

  if (normalized == 'localhost' ||
      normalized.endsWith('.localhost') ||
      normalized.endsWith('.local') ||
      normalized.endsWith('.internal') ||
      normalized.endsWith('.lan') ||
      normalized.endsWith('.home.arpa')) {
    return false;
  }

  final parsedIp = InternetAddress.tryParse(normalized);
  if (parsedIp != null) {
    return _isPublicIp(parsedIp);
  }

  if (!normalized.contains('.') || normalized.contains('..')) {
    return false;
  }
  return true;
}

bool _isPublicIp(InternetAddress addr) {
  final raw = addr.rawAddress;
  if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
    final a = raw[0];
    final b = raw[1];
    if (a == 0) return false;
    if (a == 10) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a >= 224) return false;
    return true;
  }
  if (addr.type == InternetAddressType.IPv6 && raw.length == 16) {
    final prefix15Zero = raw.take(15).every((b) => b == 0);
    if (prefix15Zero && (raw[15] == 0 || raw[15] == 1)) return false;
    if ((raw[0] & 0xFE) == 0xFC) return false;
    if (raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80) return false;
    if (raw[0] == 0xFF) return false;
    final isMapped =
        raw.take(10).every((b) => b == 0) && raw[10] == 0xFF && raw[11] == 0xFF;
    if (isMapped) {
      return _isPublicIp(
        InternetAddress.fromRawAddress(Uint8List.fromList(raw.sublist(12, 16))),
      );
    }
    return true;
  }
  return false;
}

/// Normalizes an image URL into a stable cache key.
///
/// For `lightnovel.fun` / `*.lightnovel.fun` URLs, dynamic signature query
/// parameters (`m`, `t`) are stripped, the scheme is normalized to `https`,
/// default ports and fragments are dropped, and remaining query keys are
/// sorted deterministically so refreshed signed URLs still hit local/offline
/// caches. Local `wenku-local:` URLs and non-LightNovel URLs are preserved.
String normalizeOnlineImageKey(String url) {
  if (url.startsWith('wenku-local:')) return url;
  final trimmed = url.trim();
  if (trimmed.isEmpty) return trimmed;
  final unescaped = trimmed.contains('&amp;')
      ? trimmed.replaceAll('&amp;', '&')
      : trimmed;
  final uri = Uri.tryParse(unescaped);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return trimmed;
  }
  final host = uri.host.toLowerCase();
  if (!isLightNovelImageHost(host)) return trimmed;

  final effectivePort = uri.hasPort && uri.port != 80 && uri.port != 443
      ? uri.port
      : null;
  final canonicalAuthority = Uri(
    scheme: 'https',
    userInfo: uri.userInfo,
    host: host,
    port: effectivePort,
  ).toString();

  // Preserve percent-encoded path bytes (e.g. `%2F`, `%20`) verbatim.
  final noFragment = uri.removeFragment().toString();
  final schemeEnd = noFragment.indexOf('://');
  final authorityEnd = schemeEnd >= 0
      ? noFragment.indexOf('/', schemeEnd + 3)
      : -1;
  final queryIndex = noFragment.indexOf('?');
  final String rawPath;
  if (authorityEnd < 0 || (queryIndex >= 0 && authorityEnd > queryIndex)) {
    rawPath = '';
  } else if (queryIndex >= 0) {
    rawPath = noFragment.substring(authorityEnd, queryIndex);
  } else {
    rawPath = noFragment.substring(authorityEnd);
  }

  final remaining = <String, List<String>>{};
  if (uri.hasQuery) {
    final keys = uri.queryParametersAll.keys.toList()..sort();
    for (final key in keys) {
      if (_lightNovelDynamicQueryParams.contains(key.toLowerCase())) {
        continue;
      }
      remaining[key] = uri.queryParametersAll[key]!;
    }
  }
  final base = '$canonicalAuthority$rawPath';
  if (remaining.isEmpty) return base;
  return '$base?${Uri(queryParameters: remaining).query}';
}

/// Validates image header magic bytes so HTML error pages or truncated bodies
/// returned with HTTP 200 are rejected before entering memory or disk caches.
bool isValidEncodedImageHeader(Uint8List bytes) {
  if (bytes.length < 4) return false;
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return true;
  }
  // GIF: GIF87a / GIF89a
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return true;
  }
  // WebP: RIFF....WEBP
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  // BMP: BM
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
  // ICO / CUR: 00 00 01 00 or 00 00 02 00
  if (bytes[0] == 0x00 &&
      bytes[1] == 0x00 &&
      (bytes[2] == 0x01 || bytes[2] == 0x02) &&
      bytes[3] == 0x00) {
    return true;
  }
  // AVIF / HEIF / HEIC ISO BMFF box: ....ftyp
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    return true;
  }
  // TIFF: II*\0 or MM\0*
  if ((bytes[0] == 0x49 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x2A &&
          bytes[3] == 0x00) ||
      (bytes[0] == 0x4D &&
          bytes[1] == 0x4D &&
          bytes[2] == 0x00 &&
          bytes[3] == 0x2A)) {
    return true;
  }
  return false;
}

/// HTTP failure returned by the pure-Dart online image loader.
class OnlineMediaHttpException implements Exception {
  const OnlineMediaHttpException(this.statusCode, [this.message]);

  final int statusCode;
  final String? message;

  bool get isExpiredOrForbidden => statusCode == 403 || statusCode == 410;

  @override
  String toString() => message ?? '图片请求失败 (HTTP $statusCode)';
}

/// URL allowlist policy for online cover and illustration requests.
class OnlineImagePolicy {
  const OnlineImagePolicy({
    this.allowedHosts = defaultAllowedHosts,
    this.hostCheck,
    this.allowInsecureHttp = false,
    this.allowPublicExternalHosts = false,
  });

  const OnlineImagePolicy.publicExternal({this.allowInsecureHttp = false})
    : allowedHosts = defaultAllowedHosts,
      hostCheck = null,
      allowPublicExternalHosts = true;

  static const Set<String> defaultAllowedHosts = {'lightnovel.fun'};

  final Set<String> allowedHosts;
  final bool Function(String host)? hostCheck;
  final bool allowInsecureHttp;
  final bool allowPublicExternalHosts;

  bool isAllowedHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized.isEmpty) return false;
    if (hostCheck != null) return hostCheck!(normalized);
    if (allowPublicExternalHosts) {
      return isPublicExternalHost(normalized);
    }
    return allowedHosts.any(
      (domain) => normalized == domain || normalized.endsWith('.$domain'),
    );
  }

  Uri parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 4096) {
      throw const FormatException('图片地址无效');
    }
    final normalized = trimmed.contains('&amp;')
        ? trimmed.replaceAll('&amp;', '&')
        : trimmed;
    final uri = Uri.tryParse(normalized);
    if (uri == null) throw const FormatException('图片地址格式有误');
    if (allowPublicExternalHosts &&
        !allowInsecureHttp &&
        uri.scheme.toLowerCase() == 'http' &&
        (!uri.hasPort || uri.port == 80)) {
      return _validate(uri.replace(scheme: 'https', port: 443));
    }
    return _validate(uri);
  }

  Uri redirect(Uri from, String location) {
    final trimmed = location.trim();
    if (trimmed.isEmpty || trimmed.length > 4096) {
      throw const FormatException('图片重定向地址无效');
    }
    final next = from.resolve(trimmed);
    if (!allowInsecureHttp &&
        next.scheme == 'http' &&
        (!next.hasPort || next.port == 80)) {
      return _validate(next.replace(scheme: 'https', port: 443));
    }
    return _validate(next);
  }

  Uri _validate(Uri uri) {
    final validScheme = allowInsecureHttp
        ? (uri.scheme == 'https' || uri.scheme == 'http')
        : uri.scheme == 'https';
    final validPort = allowInsecureHttp || !uri.hasPort || uri.port == 443;
    if (!validScheme ||
        !validPort ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        !isAllowedHost(uri.host)) {
      throw const FormatException('不支持的图片地址');
    }
    return uri;
  }
}

/// Bounded persistent disk LRU cache for evictable online media.
class OnlineImageDiskCache {
  OnlineImageDiskCache({
    Directory? directory,
    Future<Directory> Function()? directoryProvider,
    this.maxBytes = 128 * 1024 * 1024,
    this.maxEntries = 1024,
    this.maxItemBytes = 12 * 1024 * 1024,
    DateTime Function()? now,
  }) : _directory = directory,
       _directoryProvider = directoryProvider,
       _now = now ?? DateTime.now,
       assert(maxBytes > 0 && maxEntries > 0 && maxItemBytes > 0);

  factory OnlineImageDiskCache.forApp(
    String namespace, {
    int maxBytes = 128 * 1024 * 1024,
    int maxEntries = 1024,
  }) => OnlineImageDiskCache(
    directoryProvider: () async {
      final root = await getTemporaryDirectory();
      return Directory('${root.path}/lightnovel-media-cache-v1/$namespace');
    },
    maxBytes: maxBytes,
    maxEntries: maxEntries,
  );

  final Directory? _directory;
  final Future<Directory> Function()? _directoryProvider;
  final int maxBytes;
  final int maxEntries;
  final int maxItemBytes;
  final DateTime Function() _now;
  Directory? _resolvedDirectory;
  bool _unavailable = false;
  Future<void> _writes = Future.value();
  int _tempSeq = 0;
  int? _trackedEntries;
  int _trackedBytes = 0;
  int _writesSincePrune = 0;

  Future<Directory?> _resolveDirectory() async {
    if (_directory != null) return _directory;
    if (_resolvedDirectory != null) return _resolvedDirectory;
    if (_unavailable || _directoryProvider == null) return null;
    try {
      return _resolvedDirectory = await _directoryProvider();
    } on MissingPluginException {
      _unavailable = true;
      return null;
    } on UnimplementedError {
      _unavailable = true;
      return null;
    } catch (_) {
      return null;
    }
  }

  String _fileName(String key) => '${sha256.convert(utf8.encode(key))}.img';

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Uint8List?> read(String key) async {
    final dir = await _resolveDirectory();
    if (dir == null) return null;
    final file = File('${dir.path}/${_fileName(key)}');
    try {
      if (!await file.exists()) return null;
      final size = await file.length();
      if (size <= 0 || size > maxItemBytes) {
        await _safeDelete(file);
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty ||
          bytes.length > maxItemBytes ||
          !isValidEncodedImageHeader(bytes)) {
        await _safeDelete(file);
        return null;
      }
      try {
        await file.setLastModified(_now());
      } on FileSystemException {
        // Touch failure does not invalidate readable bytes.
      }
      return bytes.asUnmodifiableView();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> write(String key, Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > maxItemBytes ||
        bytes.length > maxBytes ||
        !isValidEncodedImageHeader(bytes)) {
      return Future.value();
    }
    return _serialize(() async {
      final dir = await _resolveDirectory();
      if (dir == null) return;
      final target = File('${dir.path}/${_fileName(key)}');
      final temp = File('${target.path}.${_tempSeq++}.part');
      try {
        await dir.create(recursive: true);
        await temp.writeAsBytes(bytes, flush: false);
        await temp.rename(target.path);
        try {
          await target.setLastModified(_now());
        } on FileSystemException {
          // Best-effort LRU timestamp.
        }
        final needsPrune =
            _trackedEntries == null ||
            _trackedEntries! + 1 > maxEntries ||
            _trackedBytes + bytes.length > maxBytes ||
            _writesSincePrune >= 24;
        if (needsPrune) {
          await _prune(dir, keepPath: target.path);
        } else {
          _trackedEntries = _trackedEntries! + 1;
          _trackedBytes += bytes.length;
          _writesSincePrune++;
        }
      } on FileSystemException {
        // An online image survives a disk-cache write error.
      } finally {
        await _safeDelete(temp);
      }
    });
  }

  Future<void> remove(String key) => _serialize(() async {
    final dir = await _resolveDirectory();
    if (dir == null) return;
    if (await _safeDelete(File('${dir.path}/${_fileName(key)}'))) {
      _trackedEntries = null;
    }
  });

  Future<void> clear() => _serialize(() async {
    final dir = await _resolveDirectory();
    if (dir == null) return;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _trackedEntries = 0;
      _trackedBytes = 0;
      _writesSincePrune = 0;
    } on FileSystemException {
      // Ignore cleanup race.
    }
  });

  Future<void> _prune(Directory dir, {required String keepPath}) async {
    final entries = <({File file, int size, DateTime modified})>[];
    var total = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.img')) continue;
      try {
        final stat = await entity.stat();
        entries.add((file: entity, size: stat.size, modified: stat.modified));
        total += stat.size;
      } on FileSystemException {
        // File vanished concurrently.
      }
    }
    var remaining = entries.length;
    if (total > maxBytes || remaining > maxEntries) {
      entries.sort((a, b) {
        final cmp = a.modified.compareTo(b.modified);
        return cmp != 0 ? cmp : a.file.path.compareTo(b.file.path);
      });
      for (final entry in entries) {
        if (total <= maxBytes && remaining <= maxEntries) break;
        if (entry.file.path == keepPath) continue;
        if (await _safeDelete(entry.file)) {
          total -= entry.size;
          remaining--;
        }
      }
    }
    _trackedEntries = remaining;
    _trackedBytes = total;
    _writesSincePrune = 0;
  }

  Future<bool> _safeDelete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
        return true;
      }
    } on FileSystemException {
      // Best-effort cleanup.
    }
    return false;
  }
}

typedef OnlineUrlRefresher = Future<String?> Function(String expiredUrl);

/// Pure-Dart HTTPS image loader with bounded in-memory + persistent disk LRU
/// caching, LightNovel.fun headers, redirect verification, and 403/410 refresh.
class OnlineMediaClient {
  OnlineMediaClient({
    this.policy = const OnlineImagePolicy(),
    OnlineImageDiskCache? diskCache,
    bool enableDiskCache = true,
    this.referer = defaultReferer,
    this.userAgent = defaultUserAgent,
    this.maxMemoryBytes = 48 * 1024 * 1024,
    this.maxMemoryEntries = 256,
    this.maxImageBytes = 12 * 1024 * 1024,
    this.connectTimeout = const Duration(seconds: 8),
    this.readTimeout = const Duration(seconds: 15),
    String Function(String url)? keyNormalizer,
    this.onRefreshUrl,
    HttpClient Function()? httpClientFactory,
  }) : diskCache = enableDiskCache
           ? (diskCache ??
                 OnlineImageDiskCache.forApp(
                   'illustrations',
                   maxBytes: 256 * 1024 * 1024,
                   maxEntries: 2048,
                 ))
           : null,
       _keyNormalizer = keyNormalizer ?? normalizeOnlineImageKey,
       _httpClientFactory = httpClientFactory,
       assert(maxMemoryBytes > 0 && maxMemoryEntries > 0 && maxImageBytes > 0);

  static const defaultReferer = 'https://www.lightnovel.fun/';
  static const defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  static const _maxRedirects = 5;

  final OnlineImagePolicy policy;
  final OnlineImageDiskCache? diskCache;
  final String referer;
  final String userAgent;
  final int maxMemoryBytes;
  final int maxMemoryEntries;
  final int maxImageBytes;
  final Duration connectTimeout;
  final Duration readTimeout;
  final String Function(String url) _keyNormalizer;
  final HttpClient Function()? _httpClientFactory;
  OnlineUrlRefresher? onRefreshUrl;

  final _memory = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  final Set<Future<void>> _pendingDiskWrites = {};
  int _memoryBytes = 0;
  HttpClient? _httpClient;

  void _scheduleDiskWrite(String key, Uint8List bytes) {
    final cache = diskCache;
    if (cache == null) return;
    late final Future<void> job;
    job = cache
        .write(key, bytes)
        .catchError((Object _) {})
        .whenComplete(() => _pendingDiskWrites.remove(job));
    _pendingDiskWrites.add(job);
    unawaited(job);
  }

  /// Waits for any background disk cache writes currently queued to complete.
  Future<void> flushDiskCache() => Future.wait(_pendingDiskWrites.toList());

  int get memoryBytes => _memoryBytes;
  int get memoryEntries => _memory.length;

  String cacheKey(String url) => _keyNormalizer(url);

  Uint8List? _touchMemory(String key) {
    final bytes = _memory.remove(key);
    if (bytes != null) _memory[key] = bytes;
    return bytes;
  }

  void _storeMemory(String key, Uint8List bytes) {
    final previous = _memory.remove(key);
    if (previous != null) _memoryBytes -= previous.length;
    if (bytes.length > maxMemoryBytes) return;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > maxMemoryBytes || _memory.length > maxMemoryEntries) {
      final removed = _memory.remove(_memory.keys.first)!;
      _memoryBytes -= removed.length;
    }
  }

  Uint8List? peek(String url) => _touchMemory(_keyNormalizer(url));

  Future<Uint8List> loadImage(
    String url, {
    bool cacheForViewing = true,
    OnlineUrlRefresher? refreshUrl,
  }) async {
    final parsed = policy.parse(url);
    final key = _keyNormalizer(url);
    final memHit = _touchMemory(key);
    if (memHit != null) return memHit;

    final diskHit = await diskCache?.read(key);
    if (diskHit != null) {
      if (cacheForViewing) _storeMemory(key, diskHit);
      return diskHit;
    }

    final pendingKey = parsed.toString();
    final existing = _pending[pendingKey];
    if (existing != null) {
      final bytes = await existing;
      if (cacheForViewing) {
        _storeMemory(key, bytes);
        _scheduleDiskWrite(key, bytes);
      }
      return bytes;
    }

    final future = _fetchWithRefresh(
      rawUrl: url,
      initialUri: parsed,
      refreshUrl: refreshUrl ?? onRefreshUrl,
    );
    _pending[pendingKey] = future;
    try {
      final bytes = await future;
      if (cacheForViewing) {
        _storeMemory(key, bytes);
        _scheduleDiskWrite(key, bytes);
      }
      return bytes;
    } finally {
      if (identical(_pending[pendingKey], future)) {
        _pending.remove(pendingKey);
      }
    }
  }

  bool _shouldSendReferer(String host) {
    final lower = host.toLowerCase();
    if (policy.hostCheck != null) return true;
    return isLightNovelImageHost(lower) ||
        lower == 'lightnovel.us' ||
        lower.endsWith('.lightnovel.us');
  }

  Future<Uint8List> _fetchWithRefresh({
    required String rawUrl,
    required Uri initialUri,
    required OnlineUrlRefresher? refreshUrl,
  }) async {
    try {
      return await _download(initialUri);
    } on OnlineMediaHttpException catch (error) {
      if (!error.isExpiredOrForbidden) rethrow;
      if (error.statusCode == 403 &&
          policy.allowPublicExternalHosts &&
          !isLightNovelImageHost(initialUri.host)) {
        try {
          return await _download(
            initialUri,
            forceSendReferer: !_shouldSendReferer(initialUri.host),
          );
        } on OnlineMediaHttpException {
          // Fall through to refreshUrl or rethrow below.
        }
      }
      if (refreshUrl == null) rethrow;
      final refreshed = (await refreshUrl(rawUrl))?.trim();
      if (refreshed == null || refreshed.isEmpty || refreshed == rawUrl.trim()) {
        rethrow;
      }
      final nextUri = policy.parse(refreshed);
      return _download(nextUri);
    }
  }

  HttpClient _client() {
    final current = _httpClient;
    if (current != null) return current;
    final created = _httpClientFactory?.call() ?? HttpClient();
    created.connectionTimeout = connectTimeout;
    created.idleTimeout = const Duration(seconds: 30);
    created.maxConnectionsPerHost = 6;
    created.userAgent = userAgent;
    return _httpClient = created;
  }

  Future<Uint8List> _download(Uri source, {bool? forceSendReferer}) async {
    var current = source;
    final client = _client();
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final request = await client.getUrl(current).timeout(connectTimeout);
      request.followRedirects = false;
      final sendReferer = forceSendReferer ?? _shouldSendReferer(current.host);
      if (sendReferer) {
        request.headers.set(HttpHeaders.refererHeader, referer);
      } else {
        request.headers.removeAll(HttpHeaders.refererHeader);
      }
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      );
      final response = await request.close().timeout(readTimeout);
      final status = response.statusCode;
      if (status == HttpStatus.movedPermanently ||
          status == HttpStatus.found ||
          status == HttpStatus.seeOther ||
          status == HttpStatus.temporaryRedirect ||
          status == HttpStatus.permanentRedirect) {
        await response.drain<void>();
        if (hop >= _maxRedirects) {
          throw const FormatException('图片重定向次数过多');
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.trim().isEmpty) {
          throw const FormatException('图片重定向地址缺失');
        }
        current = policy.redirect(current, location);
        continue;
      }
      if (status < 200 || status >= 300) {
        await response.drain<void>();
        throw OnlineMediaHttpException(status);
      }
      if (response.contentLength > maxImageBytes) {
        await response.drain<void>();
        throw const FormatException('图片大小超出限制');
      }
      final bytes = await _readBounded(response, maxImageBytes);
      if (bytes.isEmpty || !isValidEncodedImageHeader(bytes)) {
        throw const FormatException('图片数据无效');
      }
      return bytes.asUnmodifiableView();
    }
    throw const FormatException('图片重定向次数过多');
  }

  Future<Uint8List> _readBounded(
    HttpClientResponse response,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    var received = 0;
    final completer = Completer<Uint8List>();
    late final StreamSubscription<List<int>> subscription;
    final timer = Timer(readTimeout, () {
      if (!completer.isCompleted) {
        unawaited(subscription.cancel());
        completer.completeError(TimeoutException('图片下载超时', readTimeout));
      }
    });
    subscription = response.listen(
      (chunk) {
        received += chunk.length;
        if (received > limit) {
          timer.cancel();
          unawaited(subscription.cancel());
          if (!completer.isCompleted) {
            completer.completeError(const FormatException('图片大小超出限制'));
          }
          return;
        }
        builder.add(chunk);
      },
      onDone: () {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete(builder.takeBytes());
        }
      },
      onError: (Object error, StackTrace stack) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }

  Future<void> clearCache() async {
    clearMemory();
    await diskCache?.clear();
  }

  void close({bool force = false}) {
    _httpClient?.close(force: force);
    _httpClient = null;
  }
}

/// Shared application-wide online media loader for LightNovel illustrations.
abstract final class OnlineMedia {
  static OnlineMediaClient client = OnlineMediaClient(
    policy: const OnlineImagePolicy.publicExternal(),
  );

  static OnlineUrlRefresher? get onRefreshUrl => client.onRefreshUrl;
  static set onRefreshUrl(OnlineUrlRefresher? value) {
    client.onRefreshUrl = value;
  }

  static Uint8List? peek(String url) => client.peek(url);

  static Future<Uint8List> illustration(
    String url, {
    bool cacheForViewing = true,
    OnlineUrlRefresher? refreshUrl,
  }) => client.loadImage(
    url,
    cacheForViewing: cacheForViewing,
    refreshUrl: refreshUrl,
  );

  static Future<void> clearIllustrationCache() => client.clearCache();
}
