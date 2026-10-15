// Static server for local pages. Wallet extensions do not inject into file:// pages.
//
//   node serve.mjs                  this folder on 8787, opening oracle-test.html
//   node serve.mjs 8790 ../site     another folder, opening index.html
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const port = Number(process.argv[2] ?? 8787);
const root = resolve(here, process.argv[3] ?? '.') + sep;
const index = process.argv[3] ? 'index.html' : 'oracle-test.html';
const types = {
  '.html': 'text/html; charset=utf-8', '.json': 'application/json', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png',
};

createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^[\\/]+/, '') || index;
  const file = join(root, path);
  if (!file.startsWith(root)) return res.writeHead(403).end();
  let body;
  try {
    body = await readFile(file);
  } catch {
    return res.writeHead(404).end('not found');
  }
  res.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' }).end(body);
}).listen(port, '127.0.0.1', () => console.log(`http://127.0.0.1:${port}/ -> ${root}`));
