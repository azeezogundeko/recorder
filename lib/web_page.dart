/// Fallback viewer served by the phone at `http://<phone-ip>:8080`.
///
/// For Loom / Zoom / Meet, use the PhoneCam laptop app instead: it turns the
/// stream into a real webcam and microphone. This page is for quick viewing
/// and recording from any browser with nothing installed.
const String viewerPageHtml = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WiFi Mic Viewer</title>
<style>
  :root { --bg:#111315; --panel:#1a1d20; --line:#2a2e33; --text:#e8e6e3; --muted:#8b9096; --accent:#3ddc97; --rec:#ff4d4f; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
  main { max-width:900px; margin:32px auto; padding:0 16px; }
  h1 { font-size:22px; margin:0 0 4px; }
  .sub { color:var(--muted); margin:0 0 20px; }
  .panel { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:16px; margin-bottom:16px; }
  .row { display:flex; align-items:center; gap:12px; flex-wrap:wrap; }
  .status { display:flex; align-items:center; gap:8px; color:var(--muted); }
  .dot { width:9px; height:9px; border-radius:50%; background:#e6b24a; }
  .dot.ok { background:var(--accent); }
  video { width:100%; max-height:60vh; background:#000; border-radius:8px; display:block; margin:12px 0; }
  button { font:inherit; font-weight:600; border:1px solid var(--line); background:#23272b; color:var(--text); padding:10px 18px; border-radius:8px; cursor:pointer; }
  button:disabled { opacity:.45; cursor:not-allowed; }
  button.rec { background:var(--rec); color:#fff; border-color:transparent; }
  .timer { font-variant-numeric:tabular-nums; font-size:18px; }
  .small { font-size:13px; color:var(--muted); }
  ul { list-style:none; margin:0; padding:0; }
  li { display:flex; gap:12px; align-items:center; padding:8px 0; border-top:1px solid var(--line); }
  li:first-child { border-top:none; }
  a { color:var(--accent); }
</style>
</head>
<body>
<main>
  <h1>WiFi Mic</h1>
  <p class="sub">Live view from your phone. To use the phone as a webcam and mic in Loom, Zoom or Meet, install the PhoneCam app on this laptop.</p>
  <section class="panel">
    <div class="status"><span id="dot" class="dot"></span><span id="status">Connecting…</span></div>
    <video id="video" autoplay playsinline muted></video>
    <div class="row">
      <button id="soundBtn">Unmute</button>
      <button id="recBtn" disabled>Start recording</button>
      <span id="timer" class="timer"></span>
    </div>
  </section>
  <section class="panel">
    <h2 style="font-size:16px;margin:0 0 8px">Recordings</h2>
    <ul id="list"><li class="small" id="empty">No recordings yet.</li></ul>
  </section>
</main>
<script>
(() => {
  const $ = (id) => document.getElementById(id);
  const video = $('video');
  let ws, pc, recorder, chunks = [], recStart = 0, timerId;

  function status(ok, text) { $('dot').className = 'dot' + (ok ? ' ok' : ''); $('status').textContent = text; }

  function connect() {
    ws = new WebSocket(`ws://${location.host}/signal`);
    ws.onopen = () => ws.send(JSON.stringify({ type: 'hello', client: 'browser' }));
    ws.onclose = () => { closePc(); status(false, 'Phone not reachable — retrying…'); setTimeout(connect, 1500); };
    ws.onmessage = async (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.type === 'hello') status(false, msg.streaming ? `Connecting to ${msg.name}…` : `Connected to ${msg.name} — press Start on the phone`);
      if (msg.type === 'stopped') { closePc(); status(false, 'Stopped — press Start on the phone'); }
      if (msg.type === 'offer') await onOffer(msg.sdp);
    };
  }

  function closePc() {
    if (recorder && recorder.state === 'recording') recorder.stop();
    if (pc) { pc.close(); pc = null; }
    video.srcObject = null;
    $('recBtn').disabled = true;
  }

  async function onOffer(sdp) {
    closePc();
    pc = new RTCPeerConnection({ iceServers: [] });
    const stream = new MediaStream();
    pc.ontrack = (e) => { stream.addTrack(e.track); video.srcObject = stream; };
    pc.onconnectionstatechange = () => {
      if (!pc) return;
      if (pc.connectionState === 'connected') { status(true, 'Live'); $('recBtn').disabled = false; }
      if (pc.connectionState === 'failed') status(false, 'Connection failed — retrying…');
    };
    await pc.setRemoteDescription({ type: 'offer', sdp });
    await pc.setLocalDescription(await pc.createAnswer());
    await new Promise((res) => {
      if (pc.iceGatheringState === 'complete') return res();
      const t = setTimeout(res, 2000);
      pc.onicegatheringstatechange = () => { if (pc && pc.iceGatheringState === 'complete') { clearTimeout(t); res(); } };
    });
    if (pc) ws.send(JSON.stringify({ type: 'answer', sdp: pc.localDescription.sdp }));
  }

  $('soundBtn').onclick = () => {
    video.muted = !video.muted;
    $('soundBtn').textContent = video.muted ? 'Unmute' : 'Mute';
  };

  $('recBtn').onclick = () => {
    if (recorder && recorder.state === 'recording') return recorder.stop();
    const type = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm', 'audio/webm']
      .find((t) => MediaRecorder.isTypeSupported(t));
    recorder = new MediaRecorder(video.srcObject, type ? { mimeType: type } : undefined);
    chunks = [];
    recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    recorder.onstop = () => {
      clearInterval(timerId);
      $('recBtn').textContent = 'Start recording'; $('recBtn').classList.remove('rec');
      const secs = (Date.now() - recStart) / 1000;
      if (chunks.length) save(new Blob(chunks, { type: recorder.mimeType }), secs);
    };
    recorder.start(1000);
    recStart = Date.now();
    $('recBtn').textContent = 'Stop recording'; $('recBtn').classList.add('rec');
    timerId = setInterval(() => $('timer').textContent = fmt((Date.now() - recStart) / 1000), 250);
  };

  function save(blob, secs) {
    $('empty')?.remove();
    const url = URL.createObjectURL(blob);
    const d = new Date(), p = (n) => String(n).padStart(2, '0');
    const name = `recording-${d.getFullYear()}${p(d.getMonth()+1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.webm`;
    const li = document.createElement('li');
    li.innerHTML = `<span class="small">${fmt(secs)}</span><a href="${url}" download="${name}">Download ${name}</a>`;
    $('list').prepend(li);
  }

  function fmt(s) { s = Math.floor(s); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }
  connect();
})();
</script>
</body>
</html>
''';
