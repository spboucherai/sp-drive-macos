// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Scripts/fake-ai.mjs
// Description: A FAKE OpenAI-compatible chat-completions server for the local test backend (same wire format as the
// backend's own tests use). It is configured as the `maclustr` provider of the testbed so that the AI screens and the
// SPDriveNext client can be exercised end to end. No real model, no real key: the "answer" is scripted — it quotes
// the first words of the first retrieved passage and cites [1].
// Usage: node Scripts/fake-ai.mjs <port>
import http from 'node:http';
const port = Number(process.argv[2] ?? 8669);
http.createServer((req, res) => {
  let s = ''; req.on('data', (c) => (s += c)); req.on('end', () => {
    let body = {}; try { body = JSON.parse(s); } catch {}
    const text = (body.messages ?? []).map((m) => typeof m.content === 'string' ? m.content : JSON.stringify(m.content)).join('\n');
    if (/FAKE-AUTH-ERROR/.test(text)) { res.writeHead(401, { 'content-type': 'application/json' }); return res.end(JSON.stringify({ error: { message: 'bad key' } })); }
    const m = /\[1\][^\n]*\n([^\n]{1,90})/.exec(text);
    let answer = `Réponse de test (aucun vrai modèle) : « ${m ? m[1].trim() : 'passage introuvable'} » [1].`;
    // an organisation request (ai/suggest) carries a JSON payload listing files, folders and existing tags: answer a scripted proposal
    try {
      const last = (body.messages ?? []).filter((x) => x.role === 'user').pop()?.content;
      const payload = JSON.parse(typeof last === 'string' ? last : '');
      if (Array.isArray(payload.files)) {
        const folder = (payload.folders ?? [])[0];
        answer = JSON.stringify({ suggestions: payload.files.map((f) => ({ fileId: f.fileId, name: `Classé – ${f.name}`, tags: ['Factice'], ...(folder ? { folderId: folder.id } : {}), category: 'Test', reason: 'Proposition du faux fournisseur (aucun vrai modèle).' })) });
      }
    } catch { /* a question, not a payload */ }
    if (body.stream === false) { res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content: '{"suggestions":[]}' }, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 3 } })); }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const words = answer.match(/\S+\s*/g) ?? [];
    let i = 0;
    const tick = () => {
      if (i < words.length) { res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: words[i++] } }] })}\n\n`); return setTimeout(tick, 40); }
      res.write(`data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: 'stop' }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 321, completion_tokens: words.length } })}\n\n`);
      res.end('data: [DONE]\n\n');
    };
    tick();
  });
}).listen(port, '127.0.0.1');
