const loginView = document.querySelector('#login-view');
const panelView = document.querySelector('#panel-view');
const loginForm = document.querySelector('#login-form');
const accountForm = document.querySelector('#account-form');
const accountsBody = document.querySelector('#accounts-body');
const loginError = document.querySelector('#login-error');
const panelMessage = document.querySelector('#panel-message');
const credentialReceipt = document.querySelector('#credential-receipt');
const credentialList = document.querySelector('#credential-list');
const sshAccountForm = document.querySelector('#ssh-account-form');
const sshAccountsBody = document.querySelector('#ssh-accounts-body');
const sshMessage = document.querySelector('#ssh-message');

async function request(url, options = {}) {
  const response = await fetch(url, { headers: { 'Content-Type': 'application/json', ...(options.headers || {}) }, ...options });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || 'Request failed.');
  return payload;
}

function showPanel() { loginView.classList.add('hidden'); panelView.classList.remove('hidden'); loadAccounts(); loadSshAccounts(); }
function showLogin() { panelView.classList.add('hidden'); loginView.classList.remove('hidden'); }
function formatDate(value) { return new Date(value).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }); }
function showCredentials(credentials) {
  const values = [
    ['Username', credentials.username],
    ['Password', credentials.password],
    ['Server', credentials.server || 'Set VPN_SERVER_HOST in the panel environment'],
    ...(credentials.profileUris || [{ label: 'Swock profile URI', uri: credentials.profileUri }]).flatMap((profile) => [[`${profile.label || 'Swock'} URI`, profile.uri]]),
    ['Expires', formatDate(credentials.expiresAt)],
  ];
  credentialList.innerHTML = values.map(([label, value]) => `<div><dt>${label}</dt><div class="credential-row"><dd>${escapeHtml(value)}</dd><button type="button" class="copy-button" data-copy="${escapeHtml(value)}">Copy</button></div></div>`).join('');
  credentialReceipt.classList.remove('hidden');
}

async function loadAccounts() {
  const { accounts } = await request('/api/admin/accounts');
  accountsBody.innerHTML = accounts.map((account) => {
    const expired = new Date(account.expires_at) <= new Date();
    const disabled = account.disabled === 1;
    const state = disabled ? 'Disabled' : expired ? 'Expired' : 'Active';
    return `<tr><td><strong>${escapeHtml(account.username)}</strong><br><small>Created ${formatDate(account.created_at)}</small></td><td>${formatDate(account.expires_at)}</td><td><span class="badge ${state.toLowerCase()}">${state}</span></td><td><button class="action" data-id="${account.id}" data-disabled="${disabled ? '0' : '1'}">${disabled ? 'Enable' : 'Disable'}</button> <button class="action" data-reissue-profile="${account.id}" ${disabled || expired ? 'disabled' : ''}>Reissue profile</button></td></tr>`;
  }).join('') || '<tr><td colspan="4">No VPN accounts created yet.</td></tr>';
}

async function loadSshAccounts() {
  const { accounts } = await request('/api/admin/ssh-accounts');
  sshAccountsBody.innerHTML = accounts.map((account) => {
    const expired = new Date(account.expires_at) <= new Date();
    const disabled = account.disabled === 1;
    const state = disabled ? 'Disabled' : expired ? 'Expired' : 'Active';
    return `<tr><td><strong>${escapeHtml(account.username)}</strong><br><small>Created ${formatDate(account.created_at)}</small></td><td>${formatDate(account.expires_at)}</td><td><span class="badge ${state.toLowerCase()}">${state}</span></td><td><button class="action" data-ssh-id="${account.id}" data-disabled="${disabled ? '0' : '1'}">${disabled ? 'Enable' : 'Disable'}</button> <button class="action" data-ssh-delete="${account.id}" data-ssh-name="${escapeHtml(account.username)}">Delete</button></td></tr>`;
  }).join('') || '<tr><td colspan="4">No SSH accounts created yet.</td></tr>';
}

function escapeHtml(value) { return String(value).replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character])); }

loginForm.addEventListener('submit', async (event) => {
  event.preventDefault(); loginError.textContent = '';
  const form = new FormData(loginForm);
  try { await request('/api/admin/login', { method: 'POST', body: JSON.stringify(Object.fromEntries(form)) }); loginForm.reset(); showPanel(); }
  catch (error) { loginError.textContent = error.message; }
});

accountForm.addEventListener('submit', async (event) => {
  event.preventDefault(); panelMessage.textContent = '';
  const form = new FormData(accountForm);
  try { const result = await request('/api/admin/accounts', { method: 'POST', body: JSON.stringify(Object.fromEntries(form)) }); accountForm.reset(); panelMessage.textContent = 'Account created.'; showCredentials(result.credentials); await loadAccounts(); }
  catch (error) { panelMessage.textContent = error.message; }
});

sshAccountForm.addEventListener('submit', async (event) => {
  event.preventDefault(); sshMessage.textContent = '';
  const form = new FormData(sshAccountForm);
  try {
    const result = await request('/api/admin/ssh-accounts', { method: 'POST', body: JSON.stringify(Object.fromEntries(form)) });
    sshAccountForm.reset(); sshMessage.textContent = 'SSH account created.';
    const credentials = result.credentials;
    showCredentials({
      username: credentials.username,
      password: credentials.password,
      server: credentials.host,
      profileUris: [
        { label: `Direct SSH (${credentials.port})`, uri: `ssh ${credentials.username}@${credentials.host} -p ${credentials.port}` },
        { label: `SSH over TLS (${credentials.tlsPort})`, uri: `TLS tunnel: ${credentials.tlsHost}:${credentials.tlsPort} → 127.0.0.1:22` },
        { label: `SSH over WebSocket (${credentials.webSocketPort})`, uri: `ws://${credentials.webSocketHost}:${credentials.webSocketPort}/ → 127.0.0.1:22` },
      ],
      expiresAt: credentials.expiresAt,
    });
    await loadSshAccounts();
  } catch (error) { sshMessage.textContent = error.message; }
});

document.querySelector('#logout-button').addEventListener('click', async () => { await request('/api/admin/logout', { method: 'POST' }); showLogin(); });
document.querySelector('#close-receipt').addEventListener('click', () => credentialReceipt.classList.add('hidden'));
credentialList.addEventListener('click', async (event) => {
  const button = event.target.closest('[data-copy]'); if (!button) return;
  await navigator.clipboard.writeText(button.dataset.copy);
  button.textContent = 'Copied';
  setTimeout(() => { button.textContent = 'Copy'; }, 1200);
});
accountsBody.addEventListener('click', async (event) => {
  const reissueButton = event.target.closest('[data-reissue-profile]');
  if (reissueButton) {
    if (!window.confirm('Reissue this profile? The current profile will stop connecting after its active session ends.')) return;
    try {
      const result = await request(`/api/admin/accounts/${reissueButton.dataset.reissueProfile}/profile`, { method: 'POST' });
      showCredentials(result.credentials);
      panelMessage.textContent = 'New profile issued. Share it securely with the account holder.';
      await loadAccounts();
    } catch (error) { panelMessage.textContent = error.message; }
    return;
  }
  const button = event.target.closest('[data-id]'); if (!button) return;
  try { await request(`/api/admin/accounts/${button.dataset.id}`, { method: 'PATCH', body: JSON.stringify({ disabled: button.dataset.disabled === '1' }) }); await loadAccounts(); }
  catch (error) { panelMessage.textContent = error.message; }
});
sshAccountsBody.addEventListener('click', async (event) => {
  const deleteButton = event.target.closest('[data-ssh-delete]');
  if (deleteButton) {
    if (!window.confirm(`Delete SSH account “${deleteButton.dataset.sshName}”? This removes its VPS login and home directory.`)) return;
    try { await request(`/api/admin/ssh-accounts/${deleteButton.dataset.sshDelete}`, { method: 'DELETE' }); await loadSshAccounts(); sshMessage.textContent = 'SSH account deleted.'; }
    catch (error) { sshMessage.textContent = error.message; }
    return;
  }
  const button = event.target.closest('[data-ssh-id]'); if (!button) return;
  try { await request(`/api/admin/ssh-accounts/${button.dataset.sshId}`, { method: 'PATCH', body: JSON.stringify({ disabled: button.dataset.disabled === '1' }) }); await loadSshAccounts(); }
  catch (error) { sshMessage.textContent = error.message; }
});

request('/api/admin/session').then((session) => session.authenticated ? showPanel() : showLogin()).catch(showLogin);
