import 'package:flutter_webrtc/flutter_webrtc.dart';

enum Resolution {
  hd720(1280, 720, '720p'),
  hd1080(1920, 1080, '1080p');

  const Resolution(this.width, this.height, this.label);
  final int width;
  final int height;
  final String label;
}

/// Owns the phone's camera + microphone stream and the camera controls.
class MediaController {
  MediaStream? stream;
  bool frontCamera = true;
  bool torchOn = false;
  double zoom = 1.0;

  bool get isActive => stream != null;
  MediaStreamTrack? get videoTrack {
    final tracks = stream?.getVideoTracks() ?? const [];
    return tracks.isEmpty ? null : tracks.first;
  }

  bool get hasVideo => videoTrack != null;

  /// Opens mic (and camera unless [audioOnly]). Throws if permission denied.
  Future<MediaStream> start({
    required bool audioOnly,
    required Resolution resolution,
  }) async {
    await stop();
    torchOn = false;
    zoom = 1.0;
    final constraints = <String, dynamic>{
      'audio': true,
      'video': audioOnly
          ? false
          : {
              'facingMode': frontCamera ? 'user' : 'environment',
              'width': resolution.width,
              'height': resolution.height,
              'frameRate': 30,
            },
    };
    stream = await navigator.mediaDevices.getUserMedia(constraints);
    return stream!;
  }

  Future<void> switchCamera() async {
    final track = videoTrack;
    if (track == null) return;
    await Helper.switchCamera(track);
    frontCamera = !frontCamera;
    torchOn = false; // torch resets when the camera changes
    zoom = 1.0;
  }

  Future<bool> setTorch(bool on) async {
    final track = videoTrack;
    if (track == null) return false;
    if (!await track.hasTorch()) return false;
    await track.setTorch(on);
    torchOn = on;
    return true;
  }

  Future<void> setZoom(double level) async {
    final track = videoTrack;
    if (track == null) return;
    zoom = level.clamp(1.0, 8.0);
    await Helper.setZoom(track, zoom);
  }

  Future<void> setMicMuted(bool muted) async {
    for (final t in stream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  Future<void> stop() async {
    final s = stream;
    stream = null;
    if (s == null) return;
    for (final t in s.getTracks()) {
      await t.stop();
    }
    await s.dispose();
  }
}
