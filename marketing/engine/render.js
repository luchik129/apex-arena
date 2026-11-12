// usage: node render.js ../scripts/v01.json [--preview]   -> ../out/<id>.mp4 (+ _cover.jpg)
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path'); const { spawn, execFileSync } = require('child_process');
const specPath = path.resolve(process.argv[2]); const preview = process.argv.includes('--preview');
const spec = JSON.parse(fs.readFileSync(specPath, 'utf8')); const id = spec.id || path.basename(specPath, '.json');
const outDir = path.resolve(process.env.OUT_DIR || path.join(__dirname, '../out')); fs.mkdirSync(outDir, { recursive: true });
const FPS = 30;
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 1080, height: 1920 } });
  p.on('pageerror', e => console.error('ERR', e.message));
  await p.goto('file://' + __dirname + '/template.html');
  const T = await p.evaluate(s => build(s), spec); await p.waitForLoadState('networkidle'); await p.waitForTimeout(300);
  const cuts = []; let acc = 0; spec.scenes.slice(0, -1).forEach(s => { acc += s.dur; cuts.push(acc.toFixed(2)); });
  if (preview) {
    let a = 0; for (const [i, s] of spec.scenes.entries()) { await p.evaluate(t => render(t), a + s.dur * .75); await p.screenshot({ path: `${outDir}/${id}_p${i}.jpg`, quality: 80, type: 'jpeg' }); a += s.dur; }
    await b.close(); return;
  }
  const wav = `${outDir}/${id}.wav`;
  execFileSync('python3', [__dirname + '/beat.py', wav, String(T), String(spec.seed || 1), cuts.join(',')]);
  const out = `${outDir}/${id}.mp4`;
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-', '-i', wav,
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-pix_fmt', 'yuv420p', '-r', String(FPS), '-c:a', 'aac', '-b:a', '160k', '-shortest', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  const N = Math.round(T * FPS);
  for (let i = 0; i < N; i++) {
    await p.evaluate(t => render(t), i / FPS);
    const buf = await p.screenshot({ type: 'jpeg', quality: 90 });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i === Math.round((spec.cover_at || 1.2) * FPS)) fs.writeFileSync(`${outDir}/${id}_cover.jpg`, buf);
  }
  ff.stdin.end(); await new Promise(r => ff.on('close', r)); fs.unlinkSync(wav);
  await b.close(); console.log('done', out, T.toFixed(1) + 's');
})();
