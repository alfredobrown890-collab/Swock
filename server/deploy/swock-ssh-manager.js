#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const net = require('node:net');
const { spawn } = require('node:child_process');

const socketPath = process.env.SSH_MANAGER_SOCKET || '/run/swock-ssh-manager/manager.sock';
const allowedActions = new Set(['create', 'update', 'disable', 'delete']);
const usernamePattern = /^[a-z][a-z0-9._-]{2,31}$/;

try { fs.unlinkSync(socketPath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
const server = net.createServer({ allowHalfOpen: true }, (connection) => {
  let body = '';
  connection.setEncoding('utf8');
  connection.on('data', (chunk) => {
    body += chunk;
    if (Buffer.byteLength(body, 'utf8') > 8192) connection.destroy(new Error('Request too large.'));
  });
  connection.on('end', () => {
    let request;
    try {
      request = JSON.parse(body);
      if (!allowedActions.has(request.action) || !usernamePattern.test(request.username || '')) throw new Error('Invalid SSH account request.');
      if (request.action === 'create') {
        const password = String(request.password ?? '');
        const passwordBytes = Buffer.byteLength(password, 'utf8');
        if (passwordBytes === 0 || passwordBytes > 255) throw new Error('SSH passwords must be no more than 255 UTF-8 bytes.');
        if (/[\r\n\0]/.test(password)) throw new Error('SSH passwords cannot contain line breaks or NUL characters.');
      }
      if (request.action !== 'disable' && request.action !== 'delete' && !request.expiresAt) throw new Error('An expiry date is required.');
    } catch (error) {
      connection.end(JSON.stringify({ ok: false, error: error.message }));
      return;
    }
    const child = spawn('/usr/local/sbin/swock-ssh-account', [request.action, request.username, request.expiresAt || ''], { stdio: ['pipe', 'ignore', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => connection.end(JSON.stringify({ ok: false, error: error.message })));
    child.on('close', (code) => connection.end(JSON.stringify({ ok: code === 0, error: stderr.trim() || undefined })));
    child.stdin.end(request.action === 'create' ? `${request.password}\n` : '');
  });
});
server.listen(socketPath, () => fs.chmodSync(socketPath, 0o660));
