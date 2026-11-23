import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:faro/src/integrations/faro_http_client.dart';
import 'package:faro/src/integrations/http_tracking_filter.dart';
import 'package:faro/src/tracing/http_event_attributes.dart';
import 'package:faro/src/tracing/span.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RecordingProcessor implements otel.SpanProcessor {
  final ended = <otel.Span>[];

  @override
  Future<void> onStart(otel.Span span, otel.Context? parentContext) async {}
  @override
  Future<void> onEnd(otel.Span span) async => ended.add(span);
  @override
  Future<void> onNameUpdate(otel.Span span, String newName) async {}
  @override
  Future<void> shutdown() async {}
  @override
  Future<void> forceFlush() async {}
}

class _ResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _ResponseWithUrl(super.stream, super.statusCode, {required this.url});

  @override
  final Uri url;
}

class _UrlClient extends http.BaseClient {
  _UrlClient(this.finalUrl);

  final Uri finalUrl;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      _ResponseWithUrl(const Stream.empty(), 200, url: finalUrl);
}

void main() {
  final processor = _RecordingProcessor();
  late otel.Tracer tracer;
  late List<otel.Span> started;

  setUpAll(() async {
    await otel.OTel.initialize(
      serviceName: 'faro-http-client-test',
      spanProcessor: processor,
      detectPlatformResources: false,
      enableMetrics: false,
      enableLogs: false,
    );
    tracer = otel.OTel.tracerProvider().getTracer('faro-mobile-flutter.http');
  });

  setUp(() {
    processor.ended.clear();
    started = [];
  });

  tearDownAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    await otel.OTel.reset();
  });

  FaroTrackingHttpBaseClient clientFor(
    http.Client inner, {
    HttpTrackingFilter? filter,
    bool propagate = true,
  }) {
    return FaroTrackingHttpBaseClient(
      inner,
      trackingFilter: filter ?? HttpTrackingFilter(),
      shouldPropagateTrace: (_) => propagate,
      startHttpSpan: (name, {required attributes}) {
        final span = tracer.startSpan(
          name,
          kind: otel.SpanKind.client,
          attributes: otel.OTel.attributesFromMap(attributes),
        );
        started.add(span);
        return SpanProvider().getSpan(span, otel.Context.current);
      },
    );
  }

  final url = Uri.parse('https://example.com/users?token=secret&page=2');

  test('records the request and ends the span after the body', () async {
    http.BaseRequest? sent;
    final client = clientFor(
      MockClient((request) async {
        sent = request;
        return http.Response(
          '{"ok":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.post(url, body: 'hello');

    expect(response.body, '{"ok":true}');
    final span = started.single;
    expect(span.name, 'POST');
    expect(processor.ended, [span]);
    expect(span.status, otel.SpanStatusCode.Unset);
    expect(span.attributes.getString('http.request.method'), 'POST');
    expect(
      span.attributes.getString('url.full'),
      'https://example.com/users?token=REDACTED&page=2',
    );
    expect(span.attributes.getString('server.address'), 'example.com');
    expect(span.attributes.getInt('http.response.status_code'), 200);

    final traceparent = sent?.headers['traceparent'];
    expect(traceparent, isNotNull);
    expect(traceparent, contains(span.spanContext.spanId.toString()));

    expect(httpEventAttributes(span), {
      'http.request.method': 'POST',
      'http.method': 'POST',
      'http.scheme': 'https',
      'http.url': 'https://example.com/users?token=REDACTED&page=2',
      'http.host': 'example.com',
      'http.user_agent': '',
      'http.status_code': '200',
      'http.request_size': '5',
      'http.response_size': '11',
      'http.content_type': 'application/json',
    });
  });

  test('keeps the span open until the streamed body is consumed', () async {
    final body = StreamController<List<int>>();
    final client = clientFor(
      MockClient.streaming(
        (request, _) async => http.StreamedResponse(body.stream, 200),
      ),
    );

    final response = await client.send(http.Request('GET', url));
    expect(processor.ended, isEmpty);

    final bytes = response.stream.toBytes();
    body.add([1, 2, 3]);
    await body.close();

    expect(await bytes, [1, 2, 3]);
    expect(processor.ended, [started.single]);
  });

  test('ends the span when the body subscription is cancelled', () async {
    final body = StreamController<List<int>>();
    final client = clientFor(
      MockClient.streaming(
        (request, _) async => http.StreamedResponse(body.stream, 200),
      ),
    );

    final response = await client.send(http.Request('GET', url));
    await response.stream.listen((_) {}).cancel();

    await body.close();
    expect(processor.ended, [started.single]);
    expect(started.single.status, otel.SpanStatusCode.Unset);
  });

  test('marks 4xx and 5xx responses as errors', () async {
    final client = clientFor(MockClient((_) async => http.Response('', 503)));

    await client.get(url);

    final span = processor.ended.single;
    expect(span.status, otel.SpanStatusCode.Error);
    expect(span.attributes.getString('error.type'), '503');
    expect(httpEventAttributes(span)?['http.status_code'], '503');
    expect(httpEventAttributes(span)?['error.type'], '503');
  });

  test('records a failed request and rethrows the original error', () async {
    final failure = http.ClientException('XMLHttpRequest error.', url);
    final client = clientFor(MockClient((_) async => throw failure));

    await expectLater(client.get(url), throwsA(same(failure)));

    final span = processor.ended.single;
    expect(span.status, otel.SpanStatusCode.Error);
    expect(span.attributes.getString('error.type'), 'ClientException');
    expect(httpEventAttributes(span)?['http.status_code'], '0');
  });

  test('records a body failure and forwards it to the caller', () async {
    final client = clientFor(
      MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          Stream.error(http.ClientException('connection lost')),
          200,
        ),
      ),
    );

    await expectLater(client.get(url), throwsA(isA<http.ClientException>()));

    final span = processor.ended.single;
    expect(span.status, otel.SpanStatusCode.Error);
    expect(span.attributes.getString('error.type'), 'ClientException');
    // The response had arrived, so its status is kept.
    expect(httpEventAttributes(span)?['http.status_code'], '200');
  });

  test('does not add traceparent when propagation is not allowed', () async {
    http.BaseRequest? sent;
    final client = clientFor(
      MockClient((request) async {
        sent = request;
        return http.Response('', 200);
      }),
      propagate: false,
    );

    await client.get(url);

    expect(sent?.headers.containsKey('traceparent'), isFalse);
    expect(processor.ended, hasLength(1));
  });

  test('passes ignored URLs through without a span', () async {
    http.BaseRequest? sent;
    final client = clientFor(
      MockClient((request) async {
        sent = request;
        return http.Response('untouched', 200);
      }),
      filter: HttpTrackingFilter()
        ..configure(collectorUrl: url.toString(), ignoreUrls: null),
    );

    final response = await client.get(url);

    expect(response.body, 'untouched');
    expect(sent?.headers.containsKey('traceparent'), isFalse);
    expect(started, isEmpty);
  });

  test('reports unknown sizes as -1 and a missing content type', () async {
    final client = clientFor(
      MockClient.streaming(
        (request, _) async => http.StreamedResponse(const Stream.empty(), 204),
      ),
    );

    final request = http.StreamedRequest('GET', url);
    unawaited(request.sink.close());
    final response = await client.send(request);
    await response.stream.drain<void>();

    final attributes = httpEventAttributes(processor.ended.single);
    expect(attributes?['http.request_size'], '-1');
    expect(attributes?['http.response_size'], '-1');
    expect(attributes?['http.content_type'], 'null');
  });

  test('keeps the final URL reported by the inner client', () async {
    final finalUrl = Uri.parse('https://example.com/redirected');
    // MockClient rebuilds the response, so use a client that does not.
    final client = clientFor(_UrlClient(finalUrl));

    final response = await client.send(http.Request('GET', url));

    expect(response, isA<http.BaseResponseWithUrl>());
    expect((response as http.BaseResponseWithUrl).url, finalUrl);
  });

  group('FaroHttpClient off the web', () {
    test('forwards to the inner client without tracing', () async {
      http.BaseRequest? sent;
      final client = FaroHttpClient(
        MockClient((request) async {
          sent = request;
          return http.Response('plain', 200);
        }),
      );

      final response = await client.get(url);

      expect(response.body, 'plain');
      expect(sent?.headers.containsKey('traceparent'), isFalse);
    });

    test('runWithFaroHttpTracking leaves http.Client() untouched', () {
      final inner = MockClient((_) async => http.Response('', 200));

      final client = http.runWithClient(
        () => runWithFaroHttpTracking(http.Client.new),
        () => inner,
      );

      expect(client, same(inner));
    });
  });
}
