'use strict';

const WebSocket = require('ws');

const PORT = process.env.PORT ? Number(process.env.PORT) : 8080;

/** @type {Map<string, import('ws')>} */
const clients = new Map();

const wss = new WebSocket.Server({ port: PORT });

console.log(`[rootid-server] WebSocket listening on ws://0.0.0.0:${PORT}`);

wss.on('connection', (ws) => {
  /** @type {string | null} */
  let boundId = null;

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(String(raw));
    } catch {
      console.log('[warn] invalid JSON');
      return;
    }

    if (msg.type === 'ping') {
      return;
    }

    if (msg.type === 'login' && msg.id) {
      const id = String(msg.id);
      const prev = clients.get(id);
      if (prev && prev !== ws) {
        try {
          prev.close();
        } catch (_) {}
      }
      boundId = id;
      clients.set(id, ws);
      console.log(`[login] ${id} online (connections: ${clients.size})`);
      return;
    }

    if (msg.type === 'chat' && msg.to != null && msg.content != null) {
      if (!boundId) {
        console.log('[chat] rejected (not logged in)');
        return;
      }
      const targetId = String(msg.to);
      const content = String(msg.content);
      const target = clients.get(targetId);
      const out = JSON.stringify({
        type: 'chat',
        from: boundId,
        content,
      });
      if (target && target.readyState === WebSocket.OPEN) {
        target.send(out);
        console.log(`[chat] ${boundId} -> ${targetId}: ${content.slice(0, 80)}${content.length > 80 ? '…' : ''}`);
      } else {
        console.log(`[chat] ${boundId} -> ${targetId} FAILED (offline or no socket)`);
      }
    }
  });

  ws.on('close', () => {
    if (boundId && clients.get(boundId) === ws) {
      clients.delete(boundId);
      console.log(`[offline] ${boundId} (connections: ${clients.size})`);
    }
  });

  ws.on('error', (err) => {
    console.log('[ws error]', err.message);
  });
});
