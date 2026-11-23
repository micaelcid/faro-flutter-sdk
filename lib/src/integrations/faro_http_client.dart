import 'dart:async';

import 'package:faro/src/core/pod.dart';
import 'package:faro/src/device_info/platform_info_provider.dart';
import 'package:faro/src/integrations/http_trace_propagation_policy.dart';
import 'package:faro/src/integrations/http_tracking_core.dart';
import 'package:faro/src/integrations/http_tracking_filter.dart';
import 'package:faro/src/integrations/http_url_redaction.dart';
import 'package:faro/src/tracing/faro_tracer.dart';
import 'package:faro/src/tracing/span.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A `package:http` client that traces its requests on Flutter web.
///
/// Browsers do not use `dart:io`, so `FaroHttpOverrides` cannot see requests
/// there. Use this client, or [runWithFaroHttpTracking], to capture them.
///
/// On every other platform this client only forwards to [inner], because
/// `FaroHttpOverrides` already traces those requests one layer below.
class FaroHttpClient extends http.BaseClient {
  /// Wraps [inner], or the default `http.Client()` when it is omitted.
  FaroHttpClient([http.Client? inner])
    : _delegate = _createDelegate(
        inner ?? http.Client(),
        isWeb: PlatformInfoProviderFactory().create().isWeb,
      );

  final http.Client _delegate;

  static http.Client _createDelegate(http.Client inner, {required bool isWeb}) {
    // Never trace twice, for example a `FaroHttpClient()` created inside
    // `runWithFaroHttpTracking`, where `http.Client()` is already tracked.
    if (!isWeb ||
        inner is FaroHttpClient ||
        inner is FaroTrackingHttpBaseClient) {
      return inner;
    }
    return FaroTrackingHttpBaseClient(
      inner,
      trackingFilter: pod.resolve(httpTrackingFilterProvider),
      // Resolve per request: this client can outlive initialization or reset.
      startHttpSpan: (name, {required attributes}) => pod
          .resolve(faroHttpTracerProvider)
          .startSpanManual(name, attributes: attributes),
      shouldPropagateTrace: (url) =>
          pod.resolve(httpTracePropagationPolicyProvider).shouldPropagate(url),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _delegate.send(request);

  @override
  void close() => _delegate.close();
}

/// Runs [body] in a zone where `http.Client()` and the `package:http`
/// convenience functions (`http.get`, `http.post`, ...) are traced on web.
///
/// On every other platform this only calls [body].
R runWithFaroHttpTracking<R>(R Function() body) {
  if (!PlatformInfoProviderFactory().create().isWeb) {
    return body();
  }
  // `runWithClient` runs the factory in the surrounding zone, so
  // `http.Client()` here is the client the app would have used without Faro.
  return http.runWithClient(body, FaroHttpClient.new);
}

/// Traces every request sent through an inner `package:http` client.
///
/// Platform-neutral, so it can be tested on the VM. Applications use
/// [FaroHttpClient], which only installs this on web.
@visibleForTesting
class FaroTrackingHttpBaseClient extends http.BaseClient {
  FaroTrackingHttpBaseClient(
    this._inner, {
    required HttpTrackingFilter trackingFilter,
    required StartHttpSpan startHttpSpan,
    required bool Function(Uri url) shouldPropagateTrace,
  }) : _trackingFilter = trackingFilter,
       _startHttpSpan = startHttpSpan,
       _shouldPropagateTrace = shouldPropagateTrace;

  final http.Client _inner;
  final HttpTrackingFilter _trackingFilter;
  final StartHttpSpan _startHttpSpan;
  final bool Function(Uri url) _shouldPropagateTrace;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    if (!_trackingFilter.shouldTrack(url)) {
      return _inner.send(request);
    }

    final httpSpan = startHttpRequestSpan(
      _startHttpSpan,
      method: request.method,
      url: url,
      redactedUrl: redactHttpUrl(
        url,
        sensitiveQueryParameters:
            currentHttpUrlRedactionPolicy().sensitiveQueryParameters,
      ),
      // The browser sets the user agent. It is not known to the client.
      userAgent: request.headers['user-agent'] ?? '',
    );
    if (_shouldPropagateTrace(url)) {
      request.headers['traceparent'] = httpSpan.traceparent;
    }

    try {
      final response = await _inner.send(request);
      // Sizes use -1 when unknown, like `dart:io`. A browser hides
      // `content-length` from cross-origin responses that do not expose it.
      recordHttpResponse(
        httpSpan,
        statusCode: response.statusCode,
        requestSize: '${request.contentLength ?? -1}',
        responseSize: '${response.contentLength ?? -1}',
        contentType: '${response.headers['content-type']}',
      );
      return _withTrackedBody(response, httpSpan);
    } catch (error, stackTrace) {
      recordHttpError(httpSpan, error, stackTrace);
      httpSpan.end();
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

/// Returns [response] with a body that ends [span] once it is consumed,
/// fails, or is cancelled.
http.StreamedResponse _withTrackedBody(
  http.StreamedResponse response,
  Span span,
) {
  final body = _trackBody(response.stream, span);
  if (response case http.BaseResponseWithUrl(:final url)) {
    return _TrackedStreamedResponseWithUrl(body, response, url: url);
  }
  return http.StreamedResponse(
    body,
    response.statusCode,
    contentLength: response.contentLength,
    request: response.request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}

Stream<List<int>> _trackBody(Stream<List<int>> source, Span span) {
  var finished = false;
  void finish() {
    if (finished) {
      return;
    }
    finished = true;
    span.end();
  }

  StreamSubscription<List<int>>? subscription;
  late final StreamController<List<int>> controller;
  controller = StreamController<List<int>>(
    sync: true,
    onListen: () {
      subscription = source.listen(
        controller.add,
        onError: (Object error, StackTrace stackTrace) {
          if (!finished) {
            recordHttpError(span, error, stackTrace);
          }
          finish();
          controller.addError(error, stackTrace);
        },
        onDone: () {
          finish();
          controller.close();
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      finish();
      return subscription?.cancel();
    },
  );
  return controller.stream;
}

/// Keeps the final URL that `package:http` reports after redirects.
class _TrackedStreamedResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _TrackedStreamedResponseWithUrl(
    Stream<List<int>> stream,
    http.StreamedResponse response, {
    required this.url,
  }) : super(
         stream,
         response.statusCode,
         contentLength: response.contentLength,
         request: response.request,
         headers: response.headers,
         isRedirect: response.isRedirect,
         persistentConnection: response.persistentConnection,
         reasonPhrase: response.reasonPhrase,
       );

  @override
  final Uri url;
}
