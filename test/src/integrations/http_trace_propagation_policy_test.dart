import 'package:faro/src/integrations/http_trace_propagation_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  HttpTracePropagationPolicy policyFor(String page) =>
      HttpTracePropagationPolicy(pageUrl: () => Uri.parse(page));

  test('propagates to the page origin', () {
    final policy = policyFor('https://app.example.com/#/home');

    expect(
      policy.shouldPropagate(Uri.parse('https://app.example.com/api/users')),
      isTrue,
    );
  });

  test('does not propagate to another origin by default', () {
    final policy = policyFor('https://app.example.com/');

    for (final url in [
      'https://api.example.com/users',
      'http://app.example.com/users',
      'https://app.example.com:8443/users',
    ]) {
      expect(policy.shouldPropagate(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test('propagates to configured cross-origin URLs only', () {
    final policy = policyFor('https://app.example.com/')
      ..configure([RegExp(r'^https://api\.example\.com/')]);

    expect(
      policy.shouldPropagate(Uri.parse('https://api.example.com/users')),
      isTrue,
    );
    expect(
      policy.shouldPropagate(Uri.parse('https://other.example.com/users')),
      isFalse,
    );
  });

  test('configure with null clears earlier patterns', () {
    final policy = policyFor('https://app.example.com/')
      ..configure([RegExp('api')])
      ..configure(null);

    expect(
      policy.shouldPropagate(Uri.parse('https://api.example.com/users')),
      isFalse,
    );
  });
}
