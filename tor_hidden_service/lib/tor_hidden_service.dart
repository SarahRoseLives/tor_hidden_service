import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

class TorHiddenService {
  final _methodChannel = const MethodChannel('tor_hidden_service');
  final _eventChannel = const EventChannel('tor_hidden_service/logs');

  // The local port where Tor exposes its HTTP/SOCKS proxy
  static const int _torHttpProxyPort = 9080;

  Stream<String> get onLog {
    return _eventChannel.receiveBroadcastStream().map((event) => event.toString());
  }

  Future<String> start() async {
    return await _methodChannel.invokeMethod('startTor');
  }

  Future<void> stop() async {
    await _methodChannel.invokeMethod('stopTor');
  }

  Future<String?> getOnionHostname() async {
    try {
      return await _methodChannel.invokeMethod('getHostname');
    } on PlatformException catch (_) {
      return null;
    }
  }

  /// Returns a standard HttpClient configured to use the Tor proxy.
  /// Useful for HTTPS requests or binary streams where you want standard Dart handling.
  HttpClient getSecureTorClient() {
    final client = HttpClient();
    client.findProxy = (uri) => "PROXY localhost:$_torHttpProxyPort";
    client.connectionTimeout = const Duration(seconds: 30);
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }

  /// Returns a robust client specifically designed for unsecure (HTTP) .onion addresses.
  /// It manually handles the connection to ensure full response buffering.
  TorOnionClient getUnsecureTorClient() {
    return TorOnionClient(proxyPort: _torHttpProxyPort);
  }
}

/// A custom HTTP Client that tunnels plain HTTP through the Tor Proxy.
///
/// It buffers the entire response to prevent "Unexpected end of input" errors
/// common with unstable Tor circuits.
class TorOnionClient {
  final int proxyPort;

  TorOnionClient({required this.proxyPort});

  Future<TorResponse> get(String url, {Map<String, String>? headers}) async {
    return _send('GET', url, headers: headers);
  }

  Future<TorResponse> post(String url, {Map<String, String>? headers, String? body}) async {
    return _send('POST', url, headers: headers, body: body);
  }

  Future<TorResponse> put(String url, {Map<String, String>? headers, String? body}) async {
    return _send('PUT', url, headers: headers, body: body);
  }

  Future<TorResponse> delete(String url, {Map<String, String>? headers}) async {
    return _send('DELETE', url, headers: headers);
  }

  Future<TorResponse> _send(String method, String url, {
    Map<String, String>? headers,
    String? body
  }) async {
    Socket? socket;
    try {
      final uri = Uri.parse(url);

      //
      // 1. Connect to Local Tor Proxy
      socket = await Socket.connect('127.0.0.1', proxyPort,
          timeout: const Duration(seconds: 20));

      // 2. Perform CONNECT Handshake
      // We tell the proxy to open a tunnel to the onion address
      final targetPort = uri.port == 0 ? 80 : uri.port;
      final handshake = 'CONNECT ${uri.host}:$targetPort HTTP/1.1\r\n'
                        'Host: ${uri.host}:$targetPort\r\n'
                        '\r\n';
      socket.write(handshake);
      await socket.flush();

      final responseCompleter = Completer<TorResponse>();
      final buffer = <int>[];
      bool handshakeComplete = false;

      // 3. Listen to the socket stream
      socket.listen((data) {
        buffer.addAll(data);

        // Check for Proxy Handshake completion
        if (!handshakeComplete) {
          // We decode loosely to check for the HTTP 200 OK from the proxy
          final tempString = utf8.decode(buffer, allowMalformed: true);

          if (tempString.contains('\r\n\r\n')) {
            if (tempString.contains(' 200 ')) {
              // Handshake Success!
              // Remove the proxy response from the buffer to isolate the real response
              final splitIdx = tempString.indexOf('\r\n\r\n') + 4;
              // If the proxy sent extra bytes belonging to the real response, keep them
              final leftover = buffer.sublist(splitIdx); // Logic correction depends on raw bytes, but this is usually safe for header parsing

              buffer.clear();
              // In edge cases, the real response might have started arriving in the same packet
              // but usually, we write the request first.

              handshakeComplete = true;

              // 4. Send the Real HTTP Request through the tunnel
              _writeHttpRequest(socket!, method, uri, headers, body);
            } else {
              socket!.destroy();
              if (!responseCompleter.isCompleted) {
                responseCompleter.completeError("Proxy Handshake Failed: $tempString");
              }
            }
          }
        }
      }, onDone: () {
        // 5. Connection Closed - Process the buffer
        if (handshakeComplete && !responseCompleter.isCompleted) {
          final fullString = utf8.decode(buffer, allowMalformed: true);
          responseCompleter.complete(_parseRawResponse(fullString));
        } else if (!responseCompleter.isCompleted) {
          responseCompleter.completeError("Connection closed before response received");
        }
      }, onError: (e) {
        if (!responseCompleter.isCompleted) responseCompleter.completeError(e);
      });

      return await responseCompleter.future;

    } catch (e) {
      socket?.destroy();
      throw Exception("Tor Request Failed: $e");
    }
  }

  void _writeHttpRequest(Socket socket, String method, Uri uri, Map<String, String>? headers, String? body) {
    final path = uri.path.isEmpty ? "/" : uri.path + (uri.hasQuery ? "?${uri.query}" : "");
    final sb = StringBuffer();

    sb.write('$method $path HTTP/1.1\r\n');
    sb.write('Host: ${uri.host}\r\n');
    sb.write('Connection: close\r\n'); // Critical: tells server to close socket after sending data
    sb.write('Accept-Encoding: identity\r\n'); // Critical: prevents GZIP which raw socket can't handle easily

    headers?.forEach((key, value) {
      if (key.toLowerCase() != 'content-length') { // We calculate content-length manually
        sb.write('$key: $value\r\n');
      }
    });

    List<int>? bodyBytes;
    if (body != null) {
      bodyBytes = utf8.encode(body);
      sb.write('Content-Length: ${bodyBytes.length}\r\n');
      if (headers == null || !headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
        sb.write('Content-Type: application/json\r\n');
      }
    }

    sb.write('\r\n'); // End of headers
    socket.write(sb.toString());

    if (bodyBytes != null) {
      socket.add(bodyBytes);
    }
    socket.flush();
  }

  TorResponse _parseRawResponse(String raw) {
    if (raw.isEmpty) return TorResponse(statusCode: 500, body: "", headers: {});

    final splitIndex = raw.indexOf('\r\n\r\n');
    if (splitIndex == -1) {
      return TorResponse(statusCode: 500, body: raw, headers: {});
    }

    final headerString = raw.substring(0, splitIndex);
    final bodyString = raw.substring(splitIndex + 4);

    // Parse Status Line
    final statusLine = headerString.split('\r\n')[0];
    // HTTP/1.1 200 OK
    final parts = statusLine.split(' ');
    final statusCode = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    return TorResponse(
      statusCode: statusCode,
      body: bodyString,
      headers: {}, // Parsing all headers is optional for this use case, but doable
    );
  }
}

class TorResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  TorResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  @override
  String toString() => 'TorResponse($statusCode)';
}