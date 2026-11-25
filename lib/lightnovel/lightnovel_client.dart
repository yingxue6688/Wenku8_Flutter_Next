import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Response returned by an injected HTTP transport for [LightNovelClient].
class LightNovelTransportResponse {
  const LightNovelTransportResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

/// Pluggable HTTP POST transport for pure-Dart execution and unit testing.
typedef LightNovelTransport =
    Future<LightNovelTransportResponse> Function(
      Uri uri,
      Map<String, String> headers,
      String jsonBody,
      Duration timeout,
    );

/// Unified POST API callback signature shared across LightNovel services.
typedef LightNovelPost =
    Future<Map<String, dynamic>> Function(
      String path,
      Map<String, Object?> body, {
      bool commentProxy,
    });

/// Typed API error mapped from LightNovel.fun response envelopes.
class LightNovelApiError implements Exception {
  const LightNovelApiError(
    this.code,
    this.message, {
    this.data,
    this.httpStatus,
  });

  final int code;
  final String message;
  final Object? data;
  final int? httpStatus;

  bool get isUnauthorized => code == 8;
  bool get isRateLimited => code == 5 || httpStatus == 429;
  bool get isNotFound => code == 5001;

  /// Maps official LightNovel.fun error codes (`0, 2, 3, 5, 6, 7, 8, 1000,
  /// 1001, 1012, 5001`) into clean Chinese user messages.
  factory LightNovelApiError.fromEnvelope(
    int code, {
    String? serverMessage,
    Object? data,
    int? httpStatus,
  }) {
    final trimmedServer = serverMessage?.trim() ?? '';
    final dataMap = data is Map ? data : null;
    final dataMessage = dataMap?['message'] is String
        ? (dataMap!['message'] as String).trim()
        : '';

    final message = switch (code) {
      0 => '操作成功',
      2 => '密码或验证码不正确',
      3 =>
        _extractValidationMessage(data) ??
            (trimmedServer.isNotEmpty ? trimmedServer : '请求参数有误'),
      4 => '当前操作不受支持',
      5 => '请求过于频繁或受限，请稍后重试',
      6 => '无权执行当前操作',
      7 => '验证码无效或已过期，请重新获取',
      8 => '登录已过期，请重新登录',
      1000 =>
        dataMessage.isNotEmpty
            ? dataMessage
            : (trimmedServer.isNotEmpty ? trimmedServer : '操作未能完成，请稍后重试'),
      1001 => '账号不存在或用户名与密码不匹配',
      1012 => '密码强度不足（需 8-16 位，至少包含大小写字母、数字、符号中的 3 类）',
      5001 => '未找到该作品或内容已下架',
      _ =>
        dataMessage.isNotEmpty
            ? dataMessage
            : (trimmedServer.isNotEmpty ? trimmedServer : '服务器未完成本次操作，请稍后重试'),
    };

    return LightNovelApiError(
      code,
      message,
      data: data,
      httpStatus: httpStatus,
    );
  }

  static String? _extractValidationMessage(Object? data) {
    if (data is String && data.trim().isNotEmpty) {
      return data.trim();
    }
    if (data is List) {
      final parts = data
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) return parts.join('；');
      return null;
    }
    if (data is Map) {
      final messages = <String>[];
      void collect(Object? value) {
        if (value is String) {
          final text = value.trim();
          if (text.isNotEmpty && !messages.contains(text)) {
            messages.add(text);
          }
        } else if (value is List) {
          for (final item in value) {
            collect(item);
          }
        } else if (value is Map) {
          for (final entry in value.values) {
            collect(entry);
          }
        }
      }

      if (data.containsKey('message')) {
        collect(data['message']);
      }
      for (final entry in data.entries) {
        if (entry.key != 'message') {
          collect(entry.value);
        }
      }
      if (messages.isNotEmpty) return messages.join('；');
    }
    return null;
  }

  @override
  String toString() => message;
}

/// Non-200 HTTP failure when the response does not carry an API error envelope.
class LightNovelHttpException implements Exception {
  const LightNovelHttpException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Pure-Dart HTTP client for LightNovel.fun proxy APIs.
class LightNovelClient {
  LightNovelClient({
    this.baseUrl = defaultBaseUrl,
    this.commentProxyBaseUrl = defaultCommentProxyBaseUrl,
    this.timeout = const Duration(seconds: 20),
    this.maxRateLimitRetries = 3,
    this.initialRetryDelay = const Duration(milliseconds: 600),
    this.securityKeyProvider,
    this.onUnauthorized,
    LightNovelTransport? transport,
    Future<void> Function(Duration delay)? delay,
    HttpClient? httpClient,
  }) : _delay = delay ?? Future<void>.delayed,
       _httpClient = httpClient {
    _transport = transport ?? _defaultTransport;
  }

  static const defaultBaseUrl = 'https://www.lightnovel.fun/api/pc-proxy';
  static const defaultCommentProxyBaseUrl =
      'https://api.lightnovel.fun/pc-comment-proxy';

  static const defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const Map<String, String> defaultHeaders = {
    'User-Agent': defaultUserAgent,
    'Origin': 'https://www.lightnovel.fun',
    'Referer': 'https://www.lightnovel.fun/cn/',
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json',
    'Accept-Encoding': 'gzip',
  };

  final String baseUrl;
  final String commentProxyBaseUrl;
  final Duration timeout;
  final int maxRateLimitRetries;
  final Duration initialRetryDelay;
  final String? Function()? securityKeyProvider;
  final void Function()? onUnauthorized;
  final Future<void> Function(Duration delay) _delay;
  HttpClient? _httpClient;
  late final LightNovelTransport _transport;
  bool _closed = false;

  Uri _buildUri(String path, bool commentProxy) {
    final base = (commentProxy ? commentProxyBaseUrl : baseUrl).replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalizedPath');
  }

  Map<String, Object?> _prepareBody(Map<String, Object?> body) {
    final payload = Map<String, Object?>.from(body);
    final explicitKey = payload['security_key'];
    if (explicitKey is String && explicitKey.trim().isNotEmpty) {
      return payload;
    }
    final provided = securityKeyProvider?.call()?.trim();
    if (provided != null && provided.isNotEmpty) {
      payload['security_key'] = provided;
    } else {
      payload.remove('security_key');
    }
    return payload;
  }

  /// Sends a JSON POST request to the LightNovel.fun proxy endpoint and returns
  /// the unwrapped `data` map on `code == 0`.
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body, {
    bool commentProxy = false,
  }) async {
    if (_closed) {
      throw StateError('LightNovelClient has already been closed');
    }
    final uri = _buildUri(path, commentProxy);
    final encodedBody = jsonEncode(_prepareBody(body));
    final headers = Map<String, String>.from(defaultHeaders);

    LightNovelTransportResponse response;
    var attempt = 0;
    while (true) {
      response = await _transport(uri, headers, encodedBody, timeout);
      if (response.statusCode == 429 && attempt < maxRateLimitRetries) {
        await _delay(_retryDelayFor(attempt, response.headers));
        attempt++;
        continue;
      }
      break;
    }

    return _decodeResponse(response);
  }

  Duration _retryDelayFor(int attempt, Map<String, String> headers) {
    final retryAfterRaw = _headerValue(headers, 'retry-after');
    if (retryAfterRaw != null) {
      final seconds = int.tryParse(retryAfterRaw.trim());
      if (seconds != null && seconds > 0) {
        return Duration(seconds: seconds.clamp(1, 10));
      }
    }
    final factor = 1 << attempt.clamp(0, 5);
    return initialRetryDelay * factor;
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    final target = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target) return entry.value;
    }
    return null;
  }

  Map<String, dynamic> _decodeResponse(LightNovelTransportResponse response) {
    final decoded = _tryDecodeJson(response.body);
    if (decoded is Map) {
      final envelope = _toStringKeyedMap(decoded);
      final rawCode = envelope['code'];
      final code = rawCode is int
          ? rawCode
          : (rawCode is String ? int.tryParse(rawCode.trim()) : null);
      if (code != null) {
        if (code == 0) {
          final data = envelope['data'];
          if (data is Map) {
            return _toStringKeyedMap(data);
          }
          if (data is List && data.isNotEmpty) {
            return <String, dynamic>{'list': data};
          }
          return const <String, dynamic>{};
        }
        if (code == 8) {
          onUnauthorized?.call();
        }
        final serverMessage = envelope['message'] is String
            ? envelope['message'] as String
            : null;
        throw LightNovelApiError.fromEnvelope(
          code,
          serverMessage: serverMessage,
          data: envelope['data'],
          httpStatus: response.statusCode,
        );
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = switch (response.statusCode) {
        429 => '请求过于频繁，请稍后重试',
        401 || 403 => '登录状态已失效或访问受限',
        404 => '请求的资源不存在',
        _ => '服务器响应异常（HTTP ${response.statusCode}）',
      };
      throw LightNovelHttpException(response.statusCode, message);
    }

    throw const FormatException('接口返回格式有误');
  }

  static Object? _tryDecodeJson(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _toStringKeyedMap(Map source) {
    if (source is Map<String, dynamic>) return source;
    return <String, dynamic>{
      for (final entry in source.entries)
        if (entry.key != null) '${entry.key}': entry.value,
    };
  }

  HttpClient _ensureHttpClient() {
    if (_httpClient != null) return _httpClient!;
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 10
      ..autoUncompress = false;
    _httpClient = client;
    return client;
  }

  Future<LightNovelTransportResponse> _defaultTransport(
    Uri uri,
    Map<String, String> headers,
    String jsonBody,
    Duration requestTimeout,
  ) async {
    final client = _ensureHttpClient();
    HttpClientRequest? activeRequest;
    try {
      return await () async {
        final request = await client.postUrl(uri);
        activeRequest = request;
        headers.forEach((key, value) {
          request.headers.set(key, value);
        });
        final bodyBytes = utf8.encode(jsonBody);
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
        final response = await request.close();

        final encoding = response.headers
            .value(HttpHeaders.contentEncodingHeader)
            ?.toLowerCase();
        final bytesBuilder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          bytesBuilder.add(chunk);
        }
        List<int> bytes = bytesBuilder.takeBytes();
        if (encoding != null && encoding.contains('gzip')) {
          bytes = gzip.decode(bytes);
        } else if (encoding != null && encoding.contains('deflate')) {
          bytes = zlib.decode(bytes);
        }

        final responseHeaders = <String, String>{};
        response.headers.forEach((name, values) {
          if (values.isNotEmpty) {
            responseHeaders[name.toLowerCase()] = values.join(', ');
          }
        });

        return LightNovelTransportResponse(
          statusCode: response.statusCode,
          body: utf8.decode(bytes, allowMalformed: true),
          headers: responseHeaders,
        );
      }().timeout(requestTimeout);
    } on TimeoutException {
      activeRequest?.abort();
      rethrow;
    }
  }

  void close({bool force = false}) {
    _closed = true;
    _httpClient?.close(force: force);
    _httpClient = null;
  }
}
