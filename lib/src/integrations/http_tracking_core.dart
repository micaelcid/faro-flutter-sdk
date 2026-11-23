import 'package:faro/src/core/pod.dart';
import 'package:faro/src/integrations/http_url_redaction_policy.dart';
import 'package:faro/src/tracing/http_event_attributes.dart';
import 'package:faro/src/tracing/span.dart';
import 'package:faro/src/user_actions/constants.dart';

/// Starts a span for an automatically instrumented HTTP request.
typedef StartHttpSpan =
    Span Function(String name, {required Map<String, Object> attributes});

// Unknown-method handling is separate from known-method normalization.
const _knownMethods = {
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'DELETE',
  'CONNECT',
  'OPTIONS',
  'TRACE',
  'PATCH',
  'QUERY',
};

/// The URL redaction policy of the current Faro initialization.
HttpUrlRedactionPolicy currentHttpUrlRedactionPolicy() =>
    pod.resolve(httpUrlRedactionPolicyProvider);

/// Starts the span and the Faro HTTP event metadata for one request.
///
/// Shared by every HTTP instrumentation so that all platforms emit the same
/// telemetry shape. [redactedUrl] is the only form of [url] that is recorded.
Span startHttpRequestSpan(
  StartHttpSpan startHttpSpan, {
  required String method,
  required Uri url,
  required String redactedUrl,
  required String userAgent,
}) {
  final upperMethod = method.toUpperCase();
  final isKnownMethod = _knownMethods.contains(upperMethod);
  final recordedMethod = isKnownMethod ? upperMethod : method;
  final httpSpan = startHttpSpan(
    isKnownMethod ? recordedMethod : 'HTTP $method',
    attributes: {
      'http.request.method': recordedMethod,
      if (isKnownMethod && recordedMethod != method)
        'http.request.method_original': method,
      'url.full': redactedUrl,
      'server.address': url.host,
      'server.port': url.port,
      UserActionConstants.pendingOperationKey: true,
    },
  );

  initializeHttpEventAttributes(httpSpan, {
    if (isKnownMethod) 'http.request.method': recordedMethod,
    if (isKnownMethod && recordedMethod != method)
      'http.request.method_original': method,
    'http.method': recordedMethod,
    'http.scheme': url.scheme,
    'http.url': redactedUrl,
    'http.host': url.host,
    'http.user_agent': userAgent,
  });
  return httpSpan;
}

/// Records the response status and sizes once the headers have arrived.
void recordHttpResponse(
  Span span, {
  required int statusCode,
  required String requestSize,
  required String responseSize,
  required String contentType,
}) {
  preserveHttpEventErrorType(span);
  updateHttpEventAttributes(span, {
    'http.status_code': '$statusCode',
    'http.request_size': requestSize,
    'http.response_size': responseSize,
    'http.content_type': contentType,
  });
  span.setAttribute('http.response.status_code', statusCode);
  // Successful responses leave status unset. Preserve an error already
  // recorded on the span instead of replacing its diagnostic information.
  if (statusCode >= 400 && span.status != SpanStatusCode.error) {
    updateHttpEventAttributes(span, {'error.type': statusCode.toString()});
    span.setAttribute('error.type', statusCode.toString());
    span.setStatus(SpanStatusCode.error);
  }
}

/// Records a transport or body failure on the request span.
void recordHttpError(Span span, Object error, StackTrace? stackTrace) {
  preserveHttpEventErrorType(span);
  if (span is InternalSpan &&
      httpEventAttributes(span.otelSpan)?['http.status_code'] == null) {
    updateHttpEventAttributes(span, {'http.status_code': '0'});
  }
  // Keep the first error, including an HTTP error recorded before a body
  // failure. Exception types carry failure information without inventing a
  // response code or using high-cardinality exception messages as error.type.
  if (span.status != SpanStatusCode.error) {
    span.setAttribute('error.type', error.runtimeType.toString());
    span.setStatus(SpanStatusCode.error, message: error.toString());
  }
  span.recordException(error, stackTrace: stackTrace);
}
