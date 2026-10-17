const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const types = { '.js': 'text/javascript', '.html': 'text/html', '.mp4': 'video/mp4' };
(async () => {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'fcp-chrome-'));
  const server = http.createServer((request, response) => {
    const filename = path.resolve(root, '.' + new URL(request.url, 'http://localhost').pathname);
    if (!filename.startsWith(root + path.sep) || !fs.existsSync(filename) || fs.statSync(filename).isDirectory()) {
      response.writeHead(404).end(); return;
    }
    response.setHeader('Content-Type', types[path.extname(filename)] || 'application/octet-stream');
    fs.createReadStream(filename).pipe(response);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const chrome = process.env.FCP_CHROME || (process.platform === 'darwin'
    ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : 'google-chrome');
  const child = spawn(chrome, ['--headless=new', '--no-sandbox', '--remote-debugging-port=0',
    '--no-first-run', '--no-default-browser-check', '--autoplay-policy=no-user-gesture-required',
    '--user-data-dir=' + profile, 'about:blank'], { stdio: 'ignore' });
  let startupError;
  child.on('error', (error) => { startupError = error; });
  let socket;
  try {
    const activePort = path.join(profile, 'DevToolsActivePort');
    for (let i = 0; !fs.existsSync(activePort) && i < 100; i++) { if (startupError) throw startupError; await sleep(100); }
    const port = fs.readFileSync(activePort, 'utf8').split('\n')[0];
    const url = `http://127.0.0.1:${server.address().port}/tool/browser_regression.html`;
    const tab = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' })).json();
    socket = new WebSocket(tab.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    const pending = new Map(); let id = 0;
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
    };
    const command = (method, params) => new Promise((resolve) => {
      const key = ++id; pending.set(key, resolve); socket.send(JSON.stringify({ id: key, method, params }));
    });
    const check = async () => {
      for (let i = 0; i < 100; i++) {
        const ready = await command('Runtime.evaluate', { expression: 'typeof window.regression !== "undefined"', returnByValue: true });
        if (ready.result?.result?.value) break;
        await sleep(100);
      }
      const result = await command('Runtime.evaluate', { expression: 'window.regression', awaitPromise: true, returnByValue: true });
      if (result.error || result.result?.exceptionDetails) throw new Error(JSON.stringify(result));
      if (!result.result?.result?.value?.passed) throw new Error('Browser test did not complete');
      console.log('Real browser WebCodecs encode and output probe:', JSON.stringify(result.result.result.value));
    };
    let timeout;
    try {
      await Promise.race([check(), new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Browser test timed out')), 90000); })]);
    } finally { clearTimeout(timeout); }
  } finally {
    socket?.close();
    child.kill();
    await new Promise((resolve) => server.close(resolve));
    await sleep(500);
    fs.rmSync(profile, { recursive: true, force: true });
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
