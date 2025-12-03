import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tor_hidden_service/tor_hidden_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _torService = TorHiddenService();
  final ScrollController _scrollController = ScrollController();

  String _status = 'Idle';
  String _onionUrl = 'Not generated yet';
  String _torIp = 'Unknown';
  String _loopbackResult = 'Not tested';

  final List<String> _logs = [];
  bool _isRunning = false;
  HttpServer? _localServer;

  late TorOnionClient _onionClient;

  @override
  void initState() {
    super.initState();
    // Use the new robust client
    _onionClient = _torService.getUnsecureTorClient();

    _torService.onLog.listen((log) {
      if (mounted) {
        setState(() => _logs.add(log));
        _scrollToBottom();
      }
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // 🌟 HOSTING LOGIC: Simple HTTP Server
  Future<void> _startLocalServer() async {
    if (_localServer != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      _localServer = server;
      setState(() => _logs.add('🎯 Local server running on 8080'));

      server.listen((HttpRequest request) async {
        String body = "";
        if (request.method == 'POST') {
          body = await utf8.decodeStream(request);
          setState(() => _logs.add("📨 SERVER RECEIVED POST: $body"));
        }

        request.response
          ..headers.contentType = ContentType.json
          ..write('{"status": "ok", "received": "$body"}')
          ..close();
      });
    } catch (e) {
      setState(() => _logs.add("❌ Server bind error: $e"));
    }
  }

  Future<void> _initTor() async {
    setState(() {
      _status = 'Starting...';
      _isRunning = true;
      _logs.clear();
      _logs.add("⏳ Requesting Tor Start...");
    });

    try {
      await _startLocalServer();
      await _torService.start();
      final hostname = await _torService.getOnionHostname();

      setState(() {
        _status = 'Running';
        _onionUrl = hostname ?? 'Error';
        _logs.add("✅ Hidden Service: $_onionUrl");
      });
    } catch (e) {
      setState(() {
        _status = 'Error';
        _logs.add("CRITICAL ERROR: $e");
      });
    }
  }

  Future<void> _stopTor() async {
    await _localServer?.close(force: true);
    _localServer = null;
    await _torService.stop();

    setState(() {
      _status = 'Stopped';
      _isRunning = false;
      _onionUrl = 'Not generated yet';
      _torIp = 'Unknown';
      _loopbackResult = 'Not tested';
      _logs.add("🛑 Tor service stopped.");
    });
  }

  // 🔄 LOOPBACK TEST: Uses the new TorOnionClient to hit our own .onion address
  Future<void> _testLoopback() async {
    if (!_isRunning || !_onionUrl.contains(".onion")) return;

    setState(() {
      _logs.add("🔄 Testing Loopback via TorOnionClient...");
      _loopbackResult = "Connecting...";
    });

    try {
      final url = 'http://$_onionUrl';

      // 1. Test GET
      _logs.add("➡️ Sending GET to $url");
      final response = await _onionClient.get(url);
      _logs.add("⬅️ GET Response (${response.statusCode}): ${response.body}");

      // 2. Test POST
      _logs.add("➡️ Sending POST to $url");
      final postResponse = await _onionClient.post(
        url,
        body: '{"msg": "Hello Tor"}',
        headers: {'Content-Type': 'application/json'}
      );
      _logs.add("⬅️ POST Response (${postResponse.statusCode}): ${postResponse.body}");

      if (response.statusCode == 200 && postResponse.statusCode == 200) {
        setState(() {
          _loopbackResult = "Success!";
          _logs.add("✅ LOOPBACK TEST PASSED");
        });
      } else {
        throw Exception("Status codes were not 200");
      }

    } catch (e) {
      setState(() {
        _loopbackResult = "Error";
        _logs.add("❌ Loopback Error: $e");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Tor Plugin Test')),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.grey[200],
              child: Column(
                children: [
                  Text('Status: $_status', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  SelectableText(
                    _onionUrl,
                    style: const TextStyle(fontFamily: 'Courier', fontWeight: FontWeight.bold)
                  ),
                  const SizedBox(height: 15),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: _isRunning ? null : _initTor,
                        child: const Text('Start Tor'),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: _isRunning ? _stopTor : null,
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red[100]),
                        child: const Text('Stop'),
                      ),
                    ],
                  ),
                  const Divider(),
                  ElevatedButton(
                    onPressed: _isRunning ? _testLoopback : null,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green[100]),
                    child: const Text('Run Loopback Test'),
                  ),
                  Text("Loopback Result: $_loopbackResult"),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: Colors.black,
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: _logs.length,
                  itemBuilder: (context, index) => Text(
                    _logs[index],
                    style: const TextStyle(color: Colors.green, fontFamily: 'Courier', fontSize: 12)
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}