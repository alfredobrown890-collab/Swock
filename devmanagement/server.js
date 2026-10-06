require('dotenv').config();

const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
const net = require('node:net');
const express = require('express');
const helmet = require('helmet');
const session = require('express-session');
const rateLimit = require('express-rate-limit');
const bcrypt = require('bcryptjs');
const Database = require('better-sqlite3');

function decodeAdminPassword() {
  if (process.env.ADMIN_PASSWORD_B64) {
    return Buffer.from(process.env.ADMIN_PASSWORD_B64, 'base64').toString('utf8');
  }
  return process.env.ADMIN_PASSWORD || '';
}

function validatePassword(password) {
  if (typeof password !== 'string') {
    throw new Error('Password must be text.');
  }
  const byteLength = Buffer.byteLength(password, 'utf8');
  if (byteLength === 0 || byteLength > 4096) {
    throw new Error('Password must not be empty and must be no more than 4096 UTF-8 bytes.');
  }
}

function hashPassword(password) {
  validatePassword(password);
  const input = crypto.createHash('sha256').update(password, 'utf8').digest('hex');
  return bcrypt.hashSync(input, 12);
}

function verifyPassword(password, passwordHash) {
  if (typeof password !== 'string' || Buffer.byteLength(password, 'utf8') > 4096) return false;
  const prehashed = crypto.createHash('sha256').update(password, 'utf8').digest('hex');
  return bcrypt.compareSync(prehashed, passwordHash) || bcrypt.compareSync(password, passwordHash);
}

const app = express();
const port = Number(process.env.PANEL_BIND_PORT || process.env.PORT || 8080);
const dataDirectory = path.dirname(path.resolve(process.env.DB_FILE || './data/devmanagement.sqlite'));
fs.mkdirSync(dataDirectory, { recursive: true });

const adminPassword = decodeAdminPassword();
if (!process.env.SESSION_SECRET || !adminPassword) {
  throw new Error('SESSION_SECRET and ADMIN_PASSWORD_B64 (or legacy ADMIN_PASSWORD) must be set before starting the panel.');
}

const database = new Database(path.resolve(process.env.DB_FILE || './data/devmanagement.sqlite'));
database.pragma('journal_mode = WAL');
database.exec(`
  CREATE TABLE IF NOT EXISTS vpn_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    disabled INTEGER NOT NULL DEFAULT 0
  );
`);
database.exec(`
  CREATE TABLE IF NOT EXISTS ssh_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    disabled INTEGER NOT NULL DEFAULT 0
  );
`);
const accountColumns = database.prepare('PRAGMA table_info(vpn_accounts)').all().map((column) => column.name);
if (!accountColumns.includes('client_public_key')) {
  database.exec('ALTER TABLE vpn_accounts ADD COLUMN client_public_key TEXT');
}

const adminPasswordHash = hashPassword(adminPassword);
const queries = {
  list: database.prepare('SELECT id, username, expires_at, created_at, disabled FROM vpn_accounts ORDER BY created_at DESC'),
  deleteExpired: database.prepare("DELETE FROM vpn_accounts WHERE julianday(expires_at) <= julianday('now')"),
  findById: database.prepare('SELECT id, username, expires_at, created_at, disabled FROM vpn_accounts WHERE id = ?'),
  findByUsername: database.prepare('SELECT * FROM vpn_accounts WHERE username = ?'),
  create: database.prepare('INSERT INTO vpn_accounts (username, password_hash, expires_at, created_at, client_public_key) VALUES (?, ?, ?, ?, ?)'),
  update: database.prepare('UPDATE vpn_accounts SET expires_at = ?, disabled = ? WHERE id = ?'),
  resetPassword: database.prepare('UPDATE vpn_accounts SET password_hash = ? WHERE id = ?'),
  remove: database.prepare('DELETE FROM vpn_accounts WHERE id = ?'),
  listSsh: database.prepare('SELECT id, username, expires_at, created_at, disabled FROM ssh_accounts ORDER BY created_at DESC'),
  createSsh: database.prepare('INSERT INTO ssh_accounts (username, expires_at, created_at) VALUES (?, ?, ?)'),
  updateSsh: database.prepare('UPDATE ssh_accounts SET expires_at = ?, disabled = ? WHERE id = ?'),
  findSsh: database.prepare('SELECT * FROM ssh_accounts WHERE id = ?'),
  deleteSsh: database.prepare('DELETE FROM ssh_accounts WHERE id = ?'),
};

function keyToHex(key, property) {
  return Buffer.from(key.export({ format: 'jwk' })[property], 'base64url').toString('hex');
}

function createClientKeyPair() {
  const pair = crypto.generateKeyPairSync('x25519');
  return { publicKey: keyToHex(pair.publicKey, 'x'), privateKey: keyToHex(pair.privateKey, 'd') };
}

function buildProfileUri(account, clientKeys, endpoint) {
  const host = process.env.VPN_SERVER_HOST || '';
  const transport = endpoint.transport;
  if (!['tcp', 'websocket', 'websocketTls'].includes(transport)) {
    throw new Error('VPN_TRANSPORT must be tcp, websocket, or websocketTls.');
  }
  const tlsEnabled = endpoint.tls;
  const webSocketEnabled = transport === 'websocket' || transport === 'websocketTls';
  const port = endpoint.port;
  const parameters = new URLSearchParams({
    v: '2',
    name: account.username,
    port: String(port),
    transport,
    spk: process.env.VPN_SERVER_PUBLIC_KEY || '',
    cpk: clientKeys.privateKey,
    exp: account.expiresAt,
  });
  if (tlsEnabled) {
    parameters.set('tls', '1');
    parameters.set('sni', process.env.VPN_TLS_SNI || host);
  }
  if (webSocketEnabled) {
    parameters.set('ws', '1');
    parameters.set('wspath', process.env.VPN_WS_PATH || '/');
    if (process.env.VPN_WS_HOST) parameters.set('wshost', process.env.VPN_WS_HOST);
  }
  return `swock://${host}?${parameters.toString()}`;
}

function profileEndpoints() {
  const number = (name, fallback) => Number(process.env[name] || fallback);
  return [
    { label: 'WebSocket + TLS (recommended)', transport: 'websocketTls', tls: true, port: number('VPN_WSS_PORT', 9443) },
    { label: 'TLS', transport: 'tcp', tls: true, port: number('VPN_TLS_PORT', 8443) },
    { label: 'WebSocket', transport: 'websocket', tls: false, port: number('VPN_WS_PORT', 801) },
    { label: 'TCP', transport: 'tcp', tls: false, port: number('VPN_TCP_PORT', 8505) },
  ];
}

function buildProfileUris(account, clientKeys) {
  const host = String(process.env.VPN_SERVER_HOST || '').trim();
  const serverPublicKey = String(process.env.VPN_SERVER_PUBLIC_KEY || '').trim();
  if (!host || !/^[0-9a-f]{64}$/i.test(serverPublicKey)) {
    throw new Error('Configure VPN_SERVER_HOST and a valid 64-character VPN_SERVER_PUBLIC_KEY before creating accounts.');
  }
  return profileEndpoints().map((endpoint) => ({ ...endpoint, uri: buildProfileUri(account, clientKeys, endpoint) }));
}

function refreshTunnelAuthorization() {
  const file = process.env.VPN_ALLOWED_KEYS_FILE;
  if (!file) return;
  const keys = database.prepare("SELECT client_public_key FROM vpn_accounts WHERE disabled = 0 AND client_public_key IS NOT NULL AND julianday(expires_at) > julianday('now')").all()
    .map((account) => account.client_public_key)
    .filter(Boolean);
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${keys.join('\n')}\n`, { mode: 0o640 });
  fs.renameSync(temporary, file);
}

function deleteExpiredAccounts() {
  queries.deleteExpired.run();
  refreshTunnelAuthorization();
}

function manageSshAccount(action, username, expiresAt, password = '') {
  if (action === 'create') {
    const passwordBytes = Buffer.byteLength(password, 'utf8');
    if (passwordBytes === 0 || passwordBytes > 255) {
      return Promise.reject(new Error('SSH passwords must be no more than 255 UTF-8 bytes.'));
    }
    if (/[\r\n\0]/.test(password)) {
      return Promise.reject(new Error('SSH passwords cannot contain line breaks or NUL characters.'));
    }
  }
  const socketPath = process.env.SSH_MANAGER_SOCKET || '/run/swock-ssh-manager/manager.sock';
  return new Promise((resolve, reject) => {
    const client = net.createConnection({ path: socketPath });
    let response = '';
    const timeout = setTimeout(() => client.destroy(new Error('SSH account manager timed out.')), 20_000);
    client.setEncoding('utf8');
    client.on('connect', () => client.end(JSON.stringify({ action, username, expiresAt, password })));
    client.on('data', (chunk) => { response += chunk; });
    client.on('error', (error) => { clearTimeout(timeout); reject(error); });
    client.on('end', () => {
      clearTimeout(timeout);
      try {
        const result = JSON.parse(response);
        if (!result.ok) throw new Error(result.error || 'Unable to update the SSH account.');
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

deleteExpiredAccounts();
const expiryCleanupTimer = setInterval(deleteExpiredAccounts, 60 * 1000);
expiryCleanupTimer.unref();

app.set('trust proxy', 1);
app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json({ limit: '32kb' }));
app.use(express.urlencoded({ extended: false }));
app.use(session({
  name: 'swock_admin_session',
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, sameSite: 'lax', secure: process.env.NODE_ENV === 'production', maxAge: 8 * 60 * 60 * 1000 },
}));
app.use(express.static(path.join(__dirname, 'public')));

const loginLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 10, standardHeaders: true, legacyHeaders: false });

function requireAdmin(request, response, next) {
  if (request.session.admin === true) return next();
  return response.status(401).json({ error: 'Authentication required.' });
}

function validateAccountInput(body, requirePassword = true) {
  const username = String(body.username || '').trim().toLowerCase();
  const password = String(body.password ?? '');
  const expiresAt = String(body.expiresAt || '');
  if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(username)) throw new Error('Username must be 3-32 characters: letters, numbers, dot, underscore, or hyphen.');
  if (requirePassword) validatePassword(password);
  const expiry = new Date(expiresAt);
  if (Number.isNaN(expiry.valueOf()) || expiry <= new Date()) throw new Error('Expiry must be a future date and time.');
  return { username, password, expiresAt: expiry.toISOString() };
}

app.post('/api/admin/login', loginLimiter, (request, response) => {
  const { username, password } = request.body;
  if (username !== process.env.ADMIN_USERNAME || !verifyPassword(String(password ?? ''), adminPasswordHash)) {
    return response.status(401).json({ error: 'Invalid administrator credentials.' });
  }
  request.session.admin = true;
  return response.json({ ok: true });
});

app.post('/api/admin/logout', (request, response) => {
  request.session.destroy(() => response.json({ ok: true }));
});

app.get('/api/admin/session', (request, response) => response.json({ authenticated: request.session.admin === true }));
app.get('/api/admin/accounts', requireAdmin, (request, response) => {
  deleteExpiredAccounts();
  return response.json({ accounts: queries.list.all() });
});

app.get('/api/admin/ssh-accounts', requireAdmin, (request, response) => {
  return response.json({ accounts: queries.listSsh.all() });
});

app.post('/api/admin/ssh-accounts', requireAdmin, async (request, response) => {
  try {
    const account = validateAccountInput(request.body);
    const createdAt = new Date().toISOString();
    const result = queries.createSsh.run(account.username, account.expiresAt, createdAt);
    try {
      await manageSshAccount('create', account.username, account.expiresAt, account.password);
    } catch (error) {
      queries.deleteSsh.run(result.lastInsertRowid);
      throw error;
    }
    return response.status(201).json({ ok: true, credentials: {
      username: account.username, password: account.password, expiresAt: account.expiresAt,
      host: process.env.SSH_SERVER_HOST || process.env.VPN_SERVER_HOST || '',
      port: Number(process.env.SSH_PORT || 22), protocol: 'SSH',
      tlsHost: process.env.SSH_TLS_HOST || process.env.VPN_SERVER_HOST || '',
      tlsPort: Number(process.env.SSH_TLS_PORT || 444),
      webSocketHost: process.env.SSH_WS_HOST || process.env.VPN_SERVER_HOST || '',
      webSocketPort: Number(process.env.SSH_WS_PORT || 8880),
    }});
  } catch (error) {
    const message = error.code === 'SQLITE_CONSTRAINT_UNIQUE' ? 'That SSH username already exists.' : error.message;
    return response.status(400).json({ error: message });
  }
});

app.patch('/api/admin/ssh-accounts/:id', requireAdmin, async (request, response) => {
  try {
    const account = queries.findSsh.get(Number(request.params.id));
    if (!account) throw new Error('SSH account not found.');
    const expiresAt = new Date(String(request.body.expiresAt || account.expires_at));
    if (Number.isNaN(expiresAt.valueOf()) || expiresAt <= new Date()) throw new Error('Expiry must be a future date and time.');
    const disabled = request.body.disabled === true;
    await manageSshAccount(disabled ? 'disable' : 'update', account.username, expiresAt.toISOString());
    queries.updateSsh.run(expiresAt.toISOString(), disabled ? 1 : 0, account.id);
    return response.json({ ok: true });
  } catch (error) { return response.status(400).json({ error: error.message }); }
});

app.delete('/api/admin/ssh-accounts/:id', requireAdmin, async (request, response) => {
  try {
    const account = queries.findSsh.get(Number(request.params.id));
    if (!account) throw new Error('SSH account not found.');
    await manageSshAccount('delete', account.username, account.expires_at);
    queries.deleteSsh.run(account.id);
    return response.json({ ok: true });
  } catch (error) { return response.status(400).json({ error: error.message }); }
});

app.post('/api/admin/accounts', requireAdmin, (request, response) => {
  try {
    const account = validateAccountInput(request.body);
    const hash = hashPassword(account.password);
      const clientKeys = createClientKeyPair();
      const profileUris = buildProfileUris(account, clientKeys);
      queries.create.run(account.username, hash, account.expiresAt, new Date().toISOString(), clientKeys.publicKey);
      refreshTunnelAuthorization();
      return response.status(201).json({
        ok: true,
        credentials: {
          username: account.username,
          password: account.password,
          expiresAt: account.expiresAt,
          server: process.env.VPN_SERVER_HOST || '',
          serverPublicKey: process.env.VPN_SERVER_PUBLIC_KEY || '',
          clientPrivateKey: clientKeys.privateKey,
          tlsPort: Number(process.env.VPN_TLS_PORT || 8443),
          websocketPort: Number(process.env.VPN_WS_PORT || 801),
          transport: 'websocketTls',
          profileUri: profileUris[0].uri,
          profileUris,
        },
      });
  } catch (error) {
    const message = error.code === 'SQLITE_CONSTRAINT_UNIQUE' ? 'That username already exists.' : error.message;
    return response.status(400).json({ error: message });
  }
});

app.patch('/api/admin/accounts/:id', requireAdmin, (request, response) => {
  try {
    const expiry = new Date(String(request.body.expiresAt || ''));
    if (Number.isNaN(expiry.valueOf()) || expiry <= new Date()) throw new Error('Expiry must be a future date and time.');
    queries.update.run(expiry.toISOString(), request.body.disabled ? 1 : 0, Number(request.params.id));
    refreshTunnelAuthorization();
    return response.json({ ok: true });
  } catch (error) {
    return response.status(400).json({ error: error.message });
  }
});

app.post('/api/admin/accounts/:id/password', requireAdmin, (request, response) => {
  try {
    const password = String(request.body.password ?? '');
    queries.resetPassword.run(hashPassword(password), Number(request.params.id));
    return response.json({ ok: true });
  } catch (error) {
    return response.status(400).json({ error: error.message });
  }
});

app.delete('/api/admin/accounts/:id', requireAdmin, (request, response) => {
  queries.remove.run(Number(request.params.id));
  refreshTunnelAuthorization();
  return response.json({ ok: true });
});

app.post('/api/vpn/login', loginLimiter, (request, response) => {
  deleteExpiredAccounts();
  const account = queries.findByUsername.get(String(request.body.username || '').trim().toLowerCase());
  if (!account || account.disabled || new Date(account.expires_at) <= new Date() || !verifyPassword(String(request.body.password ?? ''), account.password_hash)) {
    return response.status(401).json({ error: 'Invalid or expired VPN account.' });
  }
  return response.json({
    username: account.username,
    expiresAt: account.expires_at,
    server: process.env.VPN_SERVER_HOST || null,
    transports: {
      tcp: { port: Number(process.env.VPN_TCP_PORT || 8505) },
      websocket: { port: Number(process.env.VPN_WS_PORT || 801) },
      tls: { port: Number(process.env.VPN_TLS_PORT || 8443) },
      websocketTls: { port: Number(process.env.VPN_WSS_PORT || 9443) },
    },
  });
});

app.get('/api/health', (request, response) => response.json({ ok: true, service: 'devmanagement' }));
app.listen(port, '127.0.0.1', () => console.log(`Devmanagement listening on 127.0.0.1:${port}`));
