import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'media_controller.dart';
import 'stream_server.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  StreamServer? _server;
  final _media = MediaController();
  final _preview = RTCVideoRenderer();

  StreamSubscription<void>? _serverSub;
  List<String> _addresses = [];
  String? _error;
  bool _busy = false;
  bool _streaming = false;

  // Settings
  bool _audioOnly = false;
  Resolution _resolution = Resolution.hd720;
  bool _autoStart = true;
  bool _micMuted = false;

  // Pinch-zoom bookkeeping
  double _zoomAtPinchStart = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _preview.initialize();
    final name = await _deviceName();
    final server = StreamServer(port: 8080, deviceName: name);
    _server = server;
    _serverSub = server.changes.listen((_) => _onViewersChanged());
    try {
      await server.start();
    } catch (e) {
      _error = 'Could not start on port ${server.port}: $e';
    }
    await _loadAddresses();
    if (mounted) setState(() {});
  }

  Future<String> _deviceName() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final brand = info.manufacturer.isEmpty
          ? ''
          : info.manufacturer[0].toUpperCase() + info.manufacturer.substring(1);
      return '$brand ${info.model}'.trim();
    } catch (_) {
      return 'Phone';
    }
  }

  void _onViewersChanged() {
    if (!mounted) return;
    setState(() {});
    // Seamless mode: start as soon as the laptop app connects.
    final laptopWaiting =
        _server?.viewers.any((v) => v.kind == 'laptop-app') ?? false;
    if (_autoStart && laptopWaiting && !_streaming && !_busy && _error == null) {
      _start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    final found = <String>{};
    try {
      final wifi = await NetworkInfo().getWifiIP();
      if (wifi != null && wifi.isNotEmpty) found.add(wifi);
    } catch (_) {}
    try {
      for (final i
          in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          if (!a.isLoopback) found.add(a.address);
        }
      }
    } catch (_) {}
    int rank(String ip) => ip.startsWith('192.168.')
        ? 0
        : ip.startsWith('10.')
            ? 1
            : 2;
    final list = found.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
    if (mounted) setState(() => _addresses = list);
  }

  // ---------- streaming ----------

  Future<void> _start() async {
    final server = _server;
    if (server == null || _busy) return;
    setState(() => _busy = true);
    try {
      final stream = await _media.start(
          audioOnly: _audioOnly, resolution: _resolution);
      await _media.setMicMuted(_micMuted);
      _preview.srcObject = _media.hasVideo ? stream : null;
      await server.publish(stream,
          videoBitrate:
              _resolution == Resolution.hd1080 ? 6000000 : 2500000);
      await WakelockPlus.enable();
      _streaming = true;
    } catch (e) {
      await _media.stop();
      _snack(e.toString().contains('Permission')
          ? 'Camera/microphone permission denied. Enable it in Settings > Apps > WiFi Mic > Permissions.'
          : 'Could not start: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _server?.unpublish();
      _preview.srcObject = null;
      await _media.stop();
      await WakelockPlus.disable();
      _streaming = false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Applies a setting that needs the camera reopened.
  Future<void> _restartIfStreaming() async {
    if (!_streaming) return;
    await _stop();
    // Don't let auto-start race us; start explicitly.
    await _start();
  }

  Future<void> _switchCamera() async {
    await _media.switchCamera();
    setState(() {});
  }

  Future<void> _toggleTorch() async {
    final ok = await _media.setTorch(!_media.torchOn);
    if (!ok) _snack('This camera has no flash. Switch to the back camera.');
    setState(() {});
  }

  Future<void> _toggleMic() async {
    _micMuted = !_micMuted;
    await _media.setMicMuted(_micMuted);
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serverSub?.cancel();
    _server?.dispose();
    _media.stop();
    _preview.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('WiFi Mic')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            _buildPreview(context),
            const SizedBox(height: 12),
            _buildConnection(context),
            const SizedBox(height: 12),
            _card(
              context,
              title: 'What to send',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                          value: false,
                          icon: Icon(Icons.videocam),
                          label: Text('Camera + mic')),
                      ButtonSegment(
                          value: true,
                          icon: Icon(Icons.mic),
                          label: Text('Mic only')),
                    ],
                    selected: {_audioOnly},
                    onSelectionChanged: _busy
                        ? null
                        : (s) {
                            setState(() => _audioOnly = s.first);
                            _restartIfStreaming();
                          },
                  ),
                  if (!_audioOnly) ...[
                    const SizedBox(height: 10),
                    SegmentedButton<Resolution>(
                      segments: [
                        for (final r in Resolution.values)
                          ButtonSegment(value: r, label: Text(r.label)),
                      ],
                      selected: {_resolution},
                      onSelectionChanged: _busy
                          ? null
                          : (s) {
                              setState(() => _resolution = s.first);
                              _restartIfStreaming();
                            },
                    ),
                    const SizedBox(height: 4),
                    Text('720p is smoother on busy WiFi.',
                        style: text.bodySmall),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start automatically'),
                    subtitle:
                        const Text('Begin streaming when the laptop app connects'),
                    value: _autoStart,
                    onChanged: (v) => setState(() => _autoStart = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 60,
              child: FilledButton.icon(
                onPressed: _busy || _error != null
                    ? null
                    : (_streaming ? _stop : _start),
                style: FilledButton.styleFrom(
                  backgroundColor: _streaming ? scheme.error : scheme.primary,
                  foregroundColor: _streaming ? scheme.onError : scheme.onPrimary,
                  textStyle: text.titleMedium,
                ),
                icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
                label: Text(_streaming ? 'Stop' : 'Start'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showVideo = _streaming && _media.hasVideo;
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (showVideo)
                GestureDetector(
                  onScaleStart: (_) => _zoomAtPinchStart = _media.zoom,
                  onScaleUpdate: (d) {
                    if (d.pointerCount < 2) return;
                    _media.setZoom(_zoomAtPinchStart * d.scale);
                    setState(() {});
                  },
                  child: RTCVideoView(
                    _preview,
                    mirror: _media.frontCamera,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                )
              else
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_streaming ? Icons.mic : Icons.videocam_off,
                          size: 56, color: Colors.white54),
                      const SizedBox(height: 8),
                      Text(
                        _streaming ? 'Sending microphone only' : 'Not streaming',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              if (_streaming)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _pill(
                      context,
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: scheme.error, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        const Text('LIVE',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                        if (showVideo && _media.zoom > 1.01) ...[
                          const SizedBox(width: 8),
                          Text('${_media.zoom.toStringAsFixed(1)}×',
                              style: const TextStyle(color: Colors.white70)),
                        ],
                      ])),
                ),
              if (_streaming)
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _roundButton(
                        icon: _micMuted ? Icons.mic_off : Icons.mic,
                        tooltip: _micMuted ? 'Unmute mic' : 'Mute mic',
                        active: _micMuted,
                        onTap: _toggleMic,
                      ),
                      if (showVideo) ...[
                        const SizedBox(width: 16),
                        _roundButton(
                          icon: Icons.cameraswitch,
                          tooltip: 'Switch camera',
                          onTap: _switchCamera,
                        ),
                        const SizedBox(width: 16),
                        _roundButton(
                          icon: _media.torchOn
                              ? Icons.flashlight_on
                              : Icons.flashlight_off,
                          tooltip: 'Flashlight',
                          active: _media.torchOn,
                          onTap: _toggleTorch,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (_error != null) {
      return _card(context,
          title: 'Connection',
          child: Text(_error!, style: TextStyle(color: scheme.error)));
    }
    final viewers = _server?.viewers ?? const <Viewer>[];
    final laptop = viewers.where((v) => v.kind == 'laptop-app').toList();
    final browsers = viewers.length - laptop.length;

    String line;
    IconData icon;
    Color color;
    if (laptop.isNotEmpty) {
      final live = laptop.any((v) => v.state == 'live');
      line = live
          ? 'Laptop app connected — live'
          : 'Laptop app connected${_streaming ? ' — linking…' : ''}';
      icon = Icons.laptop;
      color = live ? scheme.primary : scheme.tertiary;
    } else {
      line = 'Waiting for the laptop app…';
      icon = Icons.wifi_find;
      color = scheme.outline;
    }

    return _card(
      context,
      title: 'Connection',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(line, style: text.titleSmall)),
          ]),
          if (browsers > 0) ...[
            const SizedBox(height: 4),
            Text('$browsers browser viewer${browsers == 1 ? '' : 's'}',
                style: text.bodySmall),
          ],
          const SizedBox(height: 10),
          Text(
            'Open PhoneCam on your laptop (same WiFi) — it finds this phone automatically. '
            'Or view in a browser:',
            style: text.bodySmall,
          ),
          for (final ip in _addresses.take(2))
            Row(children: [
              Expanded(
                  child: SelectableText('http://$ip:${_server?.port ?? 8080}',
                      style: text.bodyMedium)),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: 'http://$ip:${_server?.port ?? 8080}'));
                  _snack('Copied');
                },
              ),
            ]),
          if (_addresses.isEmpty)
            Text('No WiFi network found. Connect to WiFi or turn on hotspot.',
                style: TextStyle(color: scheme.error)),
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
            color: Colors.black54, borderRadius: BorderRadius.circular(20)),
        child: child,
      );

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? Colors.white : Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(icon, color: active ? Colors.black : Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context,
      {required String title, required Widget child}) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}
