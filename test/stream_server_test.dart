import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:wifi_mic/stream_server.dart';

void main() {
  test('serves viewer page, greets viewers and tracks the laptop app', () async {
    final server = StreamServer(port: 18080, deviceName: 'Test Phone');
    await server.start();
    addTearDown(server.dispose);

    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:18080/'))).close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    expect(res.statusCode, 200);
    expect(body, contains('/signal'));

    final ws = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:18080/signal'));
    final messages = ws.stream.asBroadcastStream();
    final hello = jsonDecode(await messages.first as String);
    expect(hello, {'type': 'hello', 'name': 'Test Phone', 'streaming': false});

    ws.sink.add(jsonEncode({'type': 'hello', 'client': 'laptop-app'}));
    await server.changes.firstWhere((_) => server.viewers.any((v) => v.kind == 'laptop-app'));
    expect(server.viewers.single.kind, 'laptop-app');
    await ws.sink.close();
  });

  test('broadcasts a discovery beacon', () async {
    final listener = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
    addTearDown(listener.close);
    final server = StreamServer(port: 18081, deviceName: 'Beacon Phone');
    await server.start();
    addTearDown(server.dispose);

    final event = await listener.where((e) => e == RawSocketEvent.read)
        .map((_) => listener.receive())
        .where((d) => d != null)
        .first
        .timeout(const Duration(seconds: 5));
    final msg = jsonDecode(utf8.decode(event!.data));
    expect(msg['app'], 'wifimic');
    expect(msg['port'], 18081);
  });
}
