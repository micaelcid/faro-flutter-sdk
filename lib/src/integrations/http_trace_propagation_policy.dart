import 'package:dartypod/dartypod.dart';
import 'package:faro/src/core/pod.dart';

/// Decides which requests receive a `traceparent` header in the browser.
///
/// A browser sends a CORS preflight for a cross-origin request that carries
/// a `traceparent` header, and blocks the request when the server does not
/// allow that header. So the header is only added to same-origin requests,
/// and to cross-origin URLs the application has explicitly listed.
class HttpTracePropagationPolicy {
  HttpTracePropagationPolicy({Uri Function()? pageUrl})
    : _pageUrl = pageUrl ?? (() => Uri.base);

  final Uri Function() _pageUrl;
  List<RegExp> _corsUrls = const [];

  /// Installs the cross-origin URL patterns from the Faro configuration.
  void configure(List<RegExp>? corsUrls) {
    _corsUrls = List.unmodifiable(corsUrls ?? const <RegExp>[]);
  }

  /// Returns `true` if a `traceparent` header may be added for [url].
  bool shouldPropagate(Uri url) {
    final page = _pageUrl();
    final isSameOrigin =
        url.scheme == page.scheme &&
        url.host == page.host &&
        url.port == page.port;
    if (isSameOrigin) {
      return true;
    }
    final urlString = url.toString();
    return _corsUrls.any((pattern) => pattern.hasMatch(urlString));
  }
}

/// Resolving after a test reset returns the default policy again.
final httpTracePropagationPolicyProvider = Provider<HttpTracePropagationPolicy>(
  (_) => HttpTracePropagationPolicy(),
  scope: faroInitScope,
);
