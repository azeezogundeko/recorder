import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'web_page.dart';

/// UDP port the phone announces itself on, so the laptop app finds it
/// without typing an IP address.
const int discoveryPort = 47800;

/// One connected viewer: the PhoneCam laptop app or a browser tab.
class Viewer {
  Viewer(this.ws);
  final WebSocketChannel ws;
  RTCPeerConnection? pc;
  String kind = 'browser'; // 'laptop-app' or 'browser'
  String state = 'waiting';
  int _generation = 0;

  void send(Map<String, dynamic> msg) => ws.sink.add(jsonEncode(msg));
}

/// HTTP + WebSocket signaling server and WebRTC sender running on the phone.
///
/// `GET /`       -> browser fallback viewer page
/// `GET /signal` -> WebSocket used to exchange WebRTC offer/answer.
/// The phone always makes the offer; viewers answer.
class StreamServer {
  StreamServer({this.port = 8080, required this.deviceName});

  final int port;
  final String deviceName;
  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _beacon;
  final List<Viewer> viewers = [];
  final _changes = StreamController<void>.broadcast();

  MediaStream? _stream;
  int _videoBitrate = 2500000;

  /// Fires whenever viewers connect, disconnect or change state.
  Stream<void> get changes => _changes.stream;
  bool get isStreaming => _stream != null;

  Future<void> start() async {
    if (_http != null) return;

    final wsHandler = webSocketHandler((WebSocketChannel ws, String? _) {
      final v = Viewer(ws);
      viewers.add(v);
      _notify();
      v.send({'type': 'hello', 'name': deviceName, 'streaming': isStreaming});
      ws.stream.listen(
        (data) => _onMessage(v, data),
        onDone: () => _removeViewer(v),
        onError: (_) => _removeViewer(v),
        cancelOnError: true,
      );
      if (isStreaming) _offer(v);
    }, pingInterval: const Duration(seconds: 5));

    FutureOr<Response> handler(Request request) {
      switch (request.url.path) {
        case '':
        case 'index.html':
          return Response.ok(viewerPageHtml,
              headers: {'content-type': 'text/html; charset=utf-8'});
        case 'signal':
          return wsHandler(request);
        default:
          return Response.notFound('Not found');
      }
    }

    _http = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    await _startBeacon();
  }

  // ---------- discovery beacon ----------

  Future<void> _startBeacon() async {
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udp!.broadcastEnabled = true;
    } catch (_) {
      return; // discovery is a convenience; manual IP still works
    }
    final payload = utf8.encode(jsonEncode({
      'app': 'wifimic',
      'v': 1,
      'name': deviceName,
      'port': port,
    }));
    Future<void> tick() async {
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      try {
        for (final iface
            in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
          for (final a in iface.addresses) {
            if (a.isLoopback) continue;
            final p = a.address.split('.');
            // Assume a /24 subnet (true for nearly all home WiFi + hotspots).
            targets.add(InternetAddress('${p[0]}.${p[1]}.${p[2]}.255'));
          }
        }
      } catch (_) {}
      for (final t in targets) {
        try {
          _udp?.send(payload, t, discoveryPort);
        } catch (_) {}
      }
    }

    await tick();
    _beacon = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  // ---------- signaling ----------

  void _onMessage(Viewer v, dynamic data) async {
    if (data is! String) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'hello':
        v.kind = msg['client'] == 'laptop-app' ? 'laptop-app' : 'browser';
        _notify();
      case 'answer':
        final pc = v.pc;
        if (pc == null) return;
        try {
          await pc.setRemoteDescription(
              RTCSessionDescription(msg['sdp'] as String, 'answer'));
          await _applyBitrate(pc);
        } catch (_) {
          v.state = 'error';
          _notify();
        }
    }
  }

  void _removeViewer(Viewer v) {
    if (!viewers.remove(v)) return;
    v._generation++;
    v.pc?.close();
    v.pc = null;
    _notify();
  }

  /// Creates a fresh peer connection for [v] and sends it an offer.
  Future<void> _offer(Viewer v) async {
    final stream = _stream;
    if (stream == null) return;
    final gen = ++v._generation;
    await v.pc?.close();
    v.pc = null;

    final pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[], // same LAN: no STUN needed
      'sdpSemantics': 'unified-plan',
    });
    if (gen != v._generation) {
      await pc.close();
      return;
    }
    v.pc = pc;
    v.state = 'connecting';
    _notify();

    pc.onConnectionState = (s) {
      if (gen != v._generation) return;
      v.state = switch (s) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'live',
        RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
          'reconnecting',
        RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
        _ => 'connecting',
      };
      _notify();
      // A failed link (e.g. WiFi blip) gets a fresh offer automatically.
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
          isStreaming &&
          viewers.contains(v)) {
        Future.delayed(const Duration(seconds: 1), () => _offer(v));
      }
    };

    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }

    // Send the offer only after ICE gathering, so viewers don't need
    // trickle ICE (keeps the laptop app simple). On a LAN this is fast.
    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    final offer = await pc.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(offer);
    await gathered.future
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    if (gen != v._generation) return;
    final local = await pc.getLocalDescription();
    if (local?.sdp == null) return;
    v.send({'type': 'offer', 'sdp': local!.sdp});
  }

  Future<void> _applyBitrate(RTCPeerConnection pc) async {
    try {
      for (final sender in await pc.getSenders()) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encs = params.encodings;
        if (encs == null || encs.isEmpty) continue;
        for (final e in encs) {
          e.maxBitrate = _videoBitrate;
          e.maxFramerate = 30;
        }
        params.degradationPreference = RTCDegradationPreference.BALANCED;
        await sender.setParameters(params);
      }
    } catch (_) {
      // Not fatal: WebRTC falls back to its default bitrate.
    }
  }

  // ---------- public API ----------

  /// Starts (or restarts) sending [stream] to every viewer.
  Future<void> publish(MediaStream stream, {required int videoBitrate}) async {
    _stream = stream;
    _videoBitrate = videoBitrate;
    for (final v in viewers.toList()) {
      v.send({'type': 'hello', 'name': deviceName, 'streaming': true});
      await _offer(v);
    }
    _notify();
  }

  Future<void> unpublish() async {
    _stream = null;
    for (final v in viewers.toList()) {
      v._generation++;
      await v.pc?.close();
      v.pc = null;
      v.state = 'waiting';
      v.send({'type': 'stopped'});
    }
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> stop() async {
    _beacon?.cancel();
    _beacon = null;
    _udp?.close();
    _udp = null;
    await unpublish();
    for (final v in viewers.toList()) {
      await v.ws.sink.close();
    }
    viewers.clear();
    await _http?.close(force: true);
    _http = null;
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }
}
