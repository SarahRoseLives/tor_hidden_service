import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

// Retaining the original class name as requested
class TorHiddenService {
  final _methodChannel = const MethodChannel('tor_hidden_service');
  final _eventChannel = const EventChannel('tor_hidden_service/logs');

  // The HTTP Tunnel port defined in Kotlin/Java (Usually 9080)
  static const int _torHttpProxyPort = 9080;

  /// Listen to this stream to get real-time logs from the Tor process
  Stream<String> get onLog {
    return _eventChannel.receiveBroadcastStream().map((event) =>
        event.toString());
  }

  /// Starts the underlying Tor process.
  /// This call will hang until Tor bootstraps to 100%.
  Future<String> start() async {
    // ⚠️ CRITICAL: The _startLocalServer() call has been removed here.
    final String result = await _methodChannel.invokeMethod('startTor');
    return result;
  }

  /// Stops the underlying Tor process.
  Future<void> stop() async {
    await _methodChannel.invokeMethod('stopTor');
  }

  // This method is primarily for *hosting* a service, but is retained (commented)
  // for now in case the native code is still expecting it, but its use is
  // irrelevant for a pure client.
  /*
  Future<String?> getOnionHostname() async {
    try {
      final String hostname = await _methodChannel.invokeMethod('getHostname');
      return hostname;
    } on PlatformException catch (_) {
      return null;
    }
  }
  */

  /// Returns an HttpClient configured to route traffic through Tor's SOCKS/HTTP proxy.
  /// IGNORES SSL/TLS CERTIFICATE ERRORS for self-signed Onion sites.
  HttpClient getTorHttpClient() {
    final client = HttpClient();

    // 1. Configure the proxy to use the local Tor HTTP proxy port (9080)
    client.findProxy = (uri) {
      return "PROXY localhost:$_torHttpProxyPort";
    };

    // 2. CRITICAL FIX: Trust Self-Signed Certificates
    // Allows connection to onion services that may use self-signed certificates.
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;

    return client;
  }

  Future<String?> getOnionHostname() async {
    try {
      final String hostname = await _methodChannel.invokeMethod('getHostname');
      return hostname;
    } on PlatformException catch (_) {
      // Returns null if the native call fails (e.g., if no hidden service is configured)
      return null;
    }
  }
}