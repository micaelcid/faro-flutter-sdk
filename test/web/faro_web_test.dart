// Runs in a browser: `flutter test --platform chrome test/web`.
//
// The SDK compiles for web even when it calls `dart:io`'s `Platform`, which
// only throws when it runs. These tests execute the code in a real browser so
// that kind of regression fails here instead of in an app.
@TestOn('browser')
library;

import 'package:faro/faro.dart';
import 'package:faro/src/device_info/platform_info_provider.dart';
import 'package:faro/src/native_platform_interaction/faro_native_methods.dart';
import 'package:faro/src/offline_transport/internet_connectivity_service.dart';
import 'package:faro/src/transport/batch_transport.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockBatchTransport extends Mock implements BatchTransport {}

class _MockFaroNativeMethods extends Mock implements FaroNativeMethods {}

class _MockInternetConnectivityService extends Mock
    implements InternetConnectivityService {}

void main() {
  group('PlatformInfoProviderFactory on web', () {
    test('creates a web provider without throwing', () {
      final provider = PlatformInfoProviderFactory().create();

      expect(provider.isWeb, isTrue);
      expect(provider.isAndroid, isFalse);
      expect(provider.isIOS, isFalse);
      expect(provider.isMobile, isFalse);
      expect(provider.operatingSystem, 'web');
    });
  });

  group('OfflineTransport on web', () {
    test('does nothing and never touches connectivity', () async {
      final connectivityService = _MockInternetConnectivityService();
      final transport = OfflineTransport(
        internetConnectivityService: connectivityService,
      );

      await expectLater(transport.send({'any': 'payload'}), completes);
      await expectLater(transport.replayCachedData(), completes);

      verifyZeroInteractions(connectivityService);
    });
  });

  group('Faro on web', () {
    late _MockBatchTransport batchTransport;
    late _MockFaroNativeMethods nativeMethods;

    setUpAll(() {
      registerFallbackValue(
        FaroException('test', 'something', {
          'frames': <Map<String, dynamic>>[],
        }),
      );
      registerFallbackValue(Event('test', attributes: {'test': 'test'}));
      registerFallbackValue(FaroLog('This is a message'));
      registerFallbackValue(Measurement({'test': 123}, 'test'));
      registerFallbackValue(Meta());
    });

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await Faro.resetForTesting();
      BatchTransportFactory().reset();

      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'WebTestApp',
        packageName: 'com.grafana.web.test',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );

      batchTransport = _MockBatchTransport();
      nativeMethods = _MockFaroNativeMethods();
      BatchTransportFactory().setInstance(batchTransport);
      Faro().batchTransport = batchTransport;
      Faro().nativeChannel = nativeMethods;

      when(() => batchTransport.addLog(any())).thenAnswer((_) async {});
      when(() => batchTransport.addEvent(any())).thenAnswer((_) async {});
      when(() => batchTransport.addExceptions(any())).thenAnswer((_) async {});
      when(() => batchTransport.addMeasurement(any())).thenAnswer((_) async {});
      when(
        () => batchTransport.updatePayloadMeta(any()),
      ).thenAnswer((_) async {});
    });

    tearDown(() async {
      await Faro.resetForTesting();
      BatchTransportFactory().reset();
    });

    test('init completes and telemetry can be pushed', () async {
      await Faro().init(
        optionsConfiguration: FaroConfig(
          appName: 'WebTestApp',
          appEnv: 'test',
          apiKey: 'key',
          collectorUrl: null,
          transports: [],
          persistSession: false,
          persistUser: false,
          enableUiActivityMonitoring: false,
        ),
      );

      Faro().pushLog('hello from the browser', level: LogLevel.info);

      expect(Faro().meta.app?.name, 'WebTestApp');
      expect(Faro().meta.session?.id, isNotEmpty);
      expect(Faro().meta.os?.name, 'web');
      verify(() => batchTransport.addLog(any())).called(1);
    });

    testWidgets('lifecycle changes send events but no start measurements', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await Faro().init(
          optionsConfiguration: FaroConfig(
            appName: 'WebTestApp',
            appEnv: 'test',
            apiKey: 'key',
            collectorUrl: null,
            transports: [],
            persistSession: false,
            persistUser: false,
            enableUiActivityMonitoring: false,
          ),
        );
      });
      await tester.pumpWidget(const SizedBox());

      // The browser tab being hidden and shown again.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      final events = verify(
        () => batchTransport.addEvent(captureAny()),
      ).captured.cast<Event>();
      expect(
        events.where((event) => event.name == 'app_lifecycle_changed'),
        isNotEmpty,
      );
      // Cold and warm start are not reported on web.
      verifyNever(() => batchTransport.addMeasurement(any()));
      verifyZeroInteractions(nativeMethods);
    });

    test('init does not call native code', () async {
      await Faro().init(
        optionsConfiguration: FaroConfig(
          appName: 'WebTestApp',
          appEnv: 'test',
          apiKey: 'key',
          collectorUrl: null,
          transports: [],
          persistSession: false,
          persistUser: false,
          enableUiActivityMonitoring: false,
          // CPU and memory vitals are on by default. They and the options
          // below must be ignored on web, not started.
          anrTracking: true,
          enableCrashReporting: true,
        ),
      );

      verifyZeroInteractions(nativeMethods);
    });

    group('HTTP tracking', () {
      late List<http.BaseRequest> sent;
      late http.Client browserClient;

      // Stands in for the browser: `runWithHttpTracking` wraps whichever
      // client the surrounding zone provides.
      Future<void> runTracked(Future<void> Function() body) {
        return http.runWithClient(
          () => Faro.runWithHttpTracking(body),
          () => browserClient,
        );
      }

      Future<void> initFaro({List<RegExp>? corsUrls}) {
        return Faro().init(
          optionsConfiguration: FaroConfig(
            appName: 'WebTestApp',
            appEnv: 'test',
            apiKey: 'key',
            collectorUrl: null,
            transports: [],
            persistSession: false,
            persistUser: false,
            enableUiActivityMonitoring: false,
            propagateTraceHeaderCorsUrls: corsUrls,
          ),
        );
      }

      setUp(() {
        sent = [];
        browserClient = MockClient((request) async {
          sent.add(request);
          return http.Response('ok', 200);
        });
      });

      final sameOrigin = Uri.base.resolve('/api/users');
      final crossOrigin = Uri.parse('https://api.example.com/users');
      final traceparent = matches(
        RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'),
      );

      test('traces http.get and propagates to the page origin', () async {
        await initFaro();

        await runTracked(() async {
          final response = await http.get(sameOrigin);
          expect(response.body, 'ok');
        });

        expect(sent.single.headers['traceparent'], traceparent);
      });

      test('does not send traceparent to another origin', () async {
        await initFaro();

        await runTracked(() => http.get(crossOrigin));

        expect(sent.single.headers.containsKey('traceparent'), isFalse);
      });

      test('sends traceparent to configured cross-origin URLs', () async {
        await initFaro(corsUrls: [RegExp(r'^https://api\.example\.com/')]);

        await runTracked(() => http.get(crossOrigin));

        expect(sent.single.headers['traceparent'], traceparent);
      });

      test('http.Client() is traced, FaroHttpClient() only once', () async {
        await initFaro();

        await runTracked(() async {
          expect(http.Client(), isA<FaroHttpClient>());
          await FaroHttpClient().get(sameOrigin);
        });

        expect(sent.single.headers['traceparent'], traceparent);
      });

      test('FaroHttpClient traces without the zone', () async {
        await initFaro();

        await FaroHttpClient(browserClient).get(sameOrigin);

        expect(sent.single.headers['traceparent'], traceparent);
      });
    });
  });
}
