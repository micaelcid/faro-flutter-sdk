# Flutter Web (Beta)

**Community-supported.** Web is not currently prioritized by the
maintainers. Our focus is iOS and Android. Web fixes and features mostly
depend on community contributions.

The SDK can run in Flutter web builds. Web support is in **beta**. It covers
core telemetry, several mobile features are not available, and not everything
has been tested on web yet.

## Setup

Initialize Faro the same way as on mobile, and wrap `main` in
`Faro.runWithHttpTracking` to trace HTTP requests:

```dart
void main() => Faro.runWithHttpTracking(() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Traces HTTP on mobile. Safe to keep on web, where it does nothing.
  HttpOverrides.global = FaroHttpOverrides(HttpOverrides.current);

  // Also safe on web. Offline caching does nothing there.
  Faro().transports.add(OfflineTransport());

  await Faro().runApp(
    optionsConfiguration: FaroConfig(
      // ...
    ),
    appRunner: () => runApp(const MyApp()),
  );
});
```

## HTTP tracking

Browsers do not use `dart:io`'s `HttpClient`, so `FaroHttpOverrides` cannot
see requests on web. `Faro.runWithHttpTracking` traces requests made with
[`package:http`](https://pub.dev/packages/http) instead. On mobile it only
calls its callback, so the same `main` works on every platform.

> **The call must wrap `WidgetsFlutterBinding.ensureInitialized()`.** Flutter
> runs gesture and frame callbacks in the zone where the binding was
> initialized. If the binding is initialized first, requests made from those
> callbacks are not traced.

What is traced:

| Request made with | Traced on web |
| --- | --- |
| `http.get`, `http.post` and the other top-level functions | Yes |
| `http.Client()` | Yes |
| `FaroHttpClient(myClient)` | Yes, with or without `runWithHttpTracking` |
| A client the app constructs itself, such as `BrowserClient()` | No. Wrap it in `FaroHttpClient` |
| `dio`, `Image.network` and other code that does not use `package:http` | No |

Flutter does not guarantee the zone of every callback. If some requests are
missing, create one `FaroHttpClient()` and pass it to the code that makes them.

Requests produce the same spans and `faro.tracing.fetch` events as on mobile,
with the same `ignoreUrls` and URL sanitization. The differences are:

- `http.user_agent` is empty, because the browser sets the user agent.
- `http.response_size` is `-1` when the browser hides `content-length`, which
  it does for cross-origin responses that do not expose that header.
- A request blocked by CORS or by the network fails without a status code.

### Trace headers and CORS

On mobile every tracked request carries a `traceparent` header. In a browser
that header makes a cross-origin request need a CORS preflight, and **the
browser blocks the request if the server does not allow the header**. So on
web the header is only added to:

- requests to the page's own origin, and
- cross-origin URLs matching `propagateTraceHeaderCorsUrls`.

```dart
FaroConfig(
  // ...
  propagateTraceHeaderCorsUrls: [RegExp(r'^https://api\.example\.com/')],
)
```

List only servers that return `traceparent` in
`Access-Control-Allow-Headers`. Other cross-origin requests are still traced,
but their spans are not linked to a backend trace.

## What works on web

- Logs, events and custom measurements
- HTTP network tracking for `package:http`, once `main` is wrapped (see
  [HTTP tracking](#http-tracking))
- Manually created tracing spans
- Exceptions and automatic Flutter error capture
- Session tracking, user identity, navigation, user actions and asset tracking
- App lifecycle events (`app_lifecycle_changed`), sent when Flutter reports a
  lifecycle change, for example when the browser tab is hidden or shown again

## What is not available on web yet

| Feature                                  | Behavior on web                                    |
| ---------------------------------------- | -------------------------------------------------- |
| HTTP requests not made with `package:http` | Not tracked. This includes `dio` and `Image.network` |
| `OfflineTransport`                       | Does nothing. Web has no file system to cache payloads in, so nothing is cached or replayed. Adding it is harmless |
| CPU, memory, refresh rate and ANR vitals | Not collected. The related config flags are ignored |
| Cold and warm start measurements         | Not reported. Cold start depends on native code, and a warm start on web would only cover the time to the next frame |
| Crash reporting                          | Not collected                                      |
| Session persistence across page loads    | A page reload starts a new session                 |
| Web vitals (TTFB, FCP, LCP)              | Not collected                                      |
| Browser and page metadata                | Not sent yet (`meta.browser` and `meta.page`)      |

## Device information on web

On web, `meta.device` and the `device_*` session attributes are not meaningful
and hold placeholder values such as `unknown`. `meta.os.name` is `web`.

## Collector CORS configuration

A browser enforces CORS on requests to the collector. Based on the headers the
SDK sends and reads, the collector should:

- Allow the `x-api-key`, `x-faro-session-id` and `content-type` request headers
  in `Access-Control-Allow-Headers`, and your app's origin in
  `Access-Control-Allow-Origin`.
- List `x-faro-session-status` in `Access-Control-Expose-Headers`. Without it
  the browser hides the header from the SDK, and the SDK cannot see that a
  session was invalidated.
