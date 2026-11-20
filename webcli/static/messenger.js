// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2023-2026 Octra Labs <dev@octra.org>

var CALL_OU = '100000';
var POLL_MS = 4000;
var PAY_OU = '5000';
var HEAVY_MS = '900000';
var state = { session: null, me: '', config: null, segment: '', contact: '', contactSegment: '', theirCard: '',
  busy: false, pending: [], polling: false };

function $(id) { return document.getElementById(id); }

function setStatus(id, text, bad) {
  var node = $(id);
  node.textContent = text || '';
  node.className = 'status' + (bad ? ' err' : '');
}

function sleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

async function api(method, path, body, heavy) {
  var opts = { method: method, headers: {} };
  if (heavy) opts.headers['X-Webcli-Timeout-Ms'] = HEAVY_MS;
  if (state.session) {
    opts.headers['X-Webcli-Wallet'] = state.session.address;
    opts.headers['X-Webcli-Generation'] = String(state.session.generation);
  }
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  var res = await fetch('/api' + path, opts);
  var text = await res.text();
  var parsed;
  try { parsed = JSON.parse(text); } catch (e) { throw new Error('bad response'); }
  if (!res.ok) throw new Error(parsed.error || parsed.message || 'request failed');
  return parsed;
}

async function view(address, method, params) {
  var reply = await api('POST', '/program/view', { address: address, method: method, params: params || [] });
  return reply && typeof reply === 'object' && 'result' in reply ? reply.result : reply;
}

function pin() {
  var value = $('pin').value;
  if (!value) throw new Error('enter your wallet PIN first');
  return value;
}

async function call(address, method, params) {
  var reply = await api('POST', '/program/call',
    { address: address, method: method, params: params, ou: CALL_OU, pin: pin() });
  if (reply.error) throw new Error(typeof reply.error === 'string' ? reply.error : JSON.stringify(reply.error));
  return reply;
}

async function until(check, seconds, what) {
  var deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    try { if (await check()) return; } catch (e) { /* not there yet */ }
    await sleep(2000);
  }
  throw new Error(what + ' was not confirmed in time');
}

async function mySegment() {
  if (await view(state.config.directory, 'has', [state.me]) !== true) return '';
  return view(state.config.directory, 'segment_of', [state.me]);
}

async function refreshMailbox() {
  state.segment = await mySegment();
  if (state.segment) {
    $('mailbox').textContent = state.segment;
    $('setup-line').classList.add('hidden');
    $('contact-row').classList.remove('hidden');
  } else {
    $('mailbox').textContent = 'none yet';
    $('setup-line').classList.remove('hidden');
  }
}

async function setup() {
  if (state.busy) return;
  state.busy = true;
  $('setup').disabled = true;
  try {
    pin();
    setStatus('setup-status', 'compiling the mailbox program on the node');
    var source = await (await fetch('/messenger-segment.aml')).text();
    var compiled = await api('POST', '/contract/compile-aml', { source: source, program: true });
    setStatus('setup-status', 'deploying your mailbox');
    var deployed = await api('POST', '/contract/deploy', { pin: pin(), bytecode: compiled.program_envelope,
      deploy_payload: compiled.deploy_payload, params: '[]' });
    var address = deployed.contract_address;
    await until(async function () { return (await view(address, 'owner', [])) === state.me; }, 180, 'deployment');
    setStatus('setup-status', 'registering it in the directory');
    await call(state.config.directory, 'register', [address]);
    await until(async function () { return (await mySegment()) === address; }, 180, 'registration');
    setStatus('setup-status', 'mailbox ready');
    await refreshMailbox();
  } catch (error) {
    setStatus('setup-status', error.message, true);
  }
  $('setup').disabled = false;
  state.busy = false;
}

async function bridge(operation, body) {
  body.contact = state.contact;
  return api('POST', '/messenger/' + operation, body);
}

async function connect() {
  if (state.busy) return;
  state.busy = true;
  $('connect').disabled = true;
  try {
    var contact = $('contact').value.trim();
    if (!/^oct[1-9A-HJ-NP-Za-km-z]{44}$/.test(contact)) throw new Error('that is not an Octra address');
    if (contact === state.me) throw new Error('that is your own address');
    var registered = await view(state.config.directory, 'has', [contact]);
    if (registered !== true)
      throw new Error('no mailbox is registered for ' + contact.slice(0, 10) + '…' + contact.slice(-6)
        + '. Paste the wallet address shown as "your address" in the contact\'s tab, not their mailbox program.');
    state.contact = contact;
    state.contactSegment = await view(state.config.directory, 'segment_of', [contact]);
    state.theirCard = '';
    setStatus('contact-status', 'preparing your key for this contact');
    var mine = (await bridge('card', {})).card;
    if (!(await cardOf(state.segment, contact, mine))) {
      setStatus('contact-status', 'publishing your key for this contact');
      await call(state.segment, 'set_card', [contact, mine]);
      await until(async function () { return cardOf(state.segment, contact, mine); }, 180, 'key publication');
    }
    $('chat').classList.remove('hidden');
    $('send-row').classList.remove('hidden');
    setStatus('contact-status', 'chat open');
    await render();
    if (!state.polling) { state.polling = true; poll(); }
  } catch (error) {
    setStatus('contact-status', error.message, true);
  }
  $('connect').disabled = false;
  state.busy = false;
}

async function cardOf(segment, contact, expected) {
  if (await view(segment, 'has_card', [contact]) !== true) return '';
  var found = await view(segment, 'card', [contact]);
  if (typeof found !== 'string' || (expected !== undefined && found !== expected)) return '';
  return found;
}

async function theirCard() {
  if (!state.theirCard) state.theirCard = await cardOf(state.contactSegment, state.me);
  return state.theirCard;
}

async function sendText(text, statusId) {
  pin();
  if (!(await theirCard())) throw new Error('your contact has not opened a chat with you yet');
  setStatus(statusId, 'encrypting the message');
  var sealed = await bridge('seal', { card: state.theirCard, text: text });
  var before = Number(await view(state.segment, 'count', []));
  setStatus(statusId, 'submitting to devnet');
  await call(state.segment, 'append', [sealed.frame]);
  await render();
  setStatus(statusId, 'waiting for confirmation');
  await until(async function () { return Number(await view(state.segment, 'count', [])) > before; }, 180, 'message');
  return before;
}

async function send() {
  var text = $('text').value;
  if (!text.trim() || !state.contact) return;
  $('send').disabled = true;
  try {
    var frame = await sendText(text, 'send-status');
    $('text').value = '';
    setStatus('send-status', 'stored on chain as frame ' + frame);
  } catch (error) {
    setStatus('send-status', error.message, true);
  }
  $('send').disabled = false;
}

function formatOct(raw) {
  var text = String(raw).padStart(7, '0');
  var whole = text.slice(0, -6), fraction = text.slice(-6).replace(/0+$/, '');
  return whole + (fraction ? '.' + fraction : '');
}

function requestId() {
  var bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.prototype.map.call(bytes, function (byte) { return ('0' + byte.toString(16)).slice(-2); }).join('');
}

async function refreshEncrypted() {
  try {
    var balance = await api('GET', '/balance');
    $('encrypted').textContent = balance.encrypted_balance_known
      ? formatOct(balance.encrypted_balance) + ' OCT' : 'unknown';
  } catch (error) { $('encrypted').textContent = 'unknown'; }
}

function payNote(text) {
  try {
    var parsed = JSON.parse(text);
    var note = parsed && parsed.octra_private_payment;
    if (note && typeof note.tx === 'string' && /^[0-9a-f]{64}$/.test(note.tx)
      && typeof note.amount === 'string' && /^\d+(\.\d{1,6})?$/.test(note.amount)) return note;
  } catch (error) { /* ordinary text */ }
  return null;
}

async function pay() {
  var amount = $('amount').value.trim();
  if (!state.contact) return;
  $('pay').disabled = true;
  try {
    if (!/^\d+(\.\d{1,6})?$/.test(amount) || Number(amount) <= 0) throw new Error('enter an OCT amount');
    pin();
    if (!(await theirCard())) throw new Error('your contact has not opened a chat with you yet');
    setStatus('pay-status', 'building the encrypted transfer and its proofs, keep this tab open');
    var sent = await api('POST', '/stealth/send',
      { to: state.contact, amount: amount, pin: pin(), ou: PAY_OU, request_id: requestId() }, true);
    var tx = sent.tx_hash || sent.hash;
    if (!tx) throw new Error('the transfer returned no transaction hash');
    await sendText(JSON.stringify({ octra_private_payment: { amount: amount, tx: tx } }), 'pay-status');
    $('amount').value = '';
    setStatus('pay-status', 'sent ' + amount + ' OCT privately');
    refreshEncrypted();
  } catch (error) {
    setStatus('pay-status', error.message, true);
  }
  $('pay').disabled = false;
}

async function claim(tx, button) {
  button.disabled = true;
  try {
    pin();
    setStatus('pay-status', 'looking for the payment on chain');
    var scan = await api('GET', '/stealth/scan', undefined, true);
    var output = (scan.outputs || []).filter(function (item) { return item.tx_hash === tx; })[0];
    if (!output) {
      if (localStorage.getItem('claimed:' + tx)) throw new Error('this payment is already claimed');
      throw new Error('the payment is not visible yet, try again in a few seconds');
    }
    if (!output.claimable) throw new Error('payment cannot be claimed: ' + (output.claim_status || 'not ready'));
    setStatus('pay-status', 'claiming ' + formatOct(output.amount_raw) + ' OCT into your encrypted balance');
    await api('POST', '/stealth/claim',
      { ids: [output.id], pin: pin(), ou: PAY_OU, request_id: requestId() }, true);
    try { localStorage.setItem('claimed:' + tx, formatOct(output.amount_raw)); } catch (error) { /* display only */ }
    setStatus('pay-status', 'claimed ' + formatOct(output.amount_raw) + ' OCT, confirmed by the chain not by the message');
    await render();
    setTimeout(refreshEncrypted, 15000);
  } catch (error) {
    setStatus('pay-status', error.message, true);
    button.disabled = false;
  }
}

async function receive() {
  var known = await bridge('history', {});
  var count = Number(await view(state.contactSegment, 'count', []));
  for (var sequence = known.next_incoming; sequence < count; sequence++) {
    var frame = await view(state.contactSegment, 'get', [sequence]);
    var sender = await view(state.contactSegment, 'sender', [sequence]);
    var epoch = Number(await view(state.contactSegment, 'epoch_of', [sequence]));
    await bridge('open', { sequence: sequence, frame: frame, sender: sender, epoch: epoch });
  }
  return count > known.next_incoming;
}

async function render() {
  var known = await bridge('history', {});
  var chat = $('chat');
  var atBottom = chat.scrollHeight - chat.scrollTop - chat.clientHeight < 40;
  while (chat.firstChild) chat.removeChild(chat.firstChild);
  if (!known.entries.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = 'no messages yet';
    chat.appendChild(empty);
    return;
  }
  known.entries.sort(function (a, b) { return a.time - b.time; }).forEach(function (entry) {
    var node = document.createElement('div');
    node.className = 'msg ' + entry.direction + (entry.error ? ' bad' : '');
    var note = entry.error ? null : payNote(entry.text);
    if (note) {
      node.className += ' pay';
      node.appendChild(document.createTextNode('private payment'));
      var amount = document.createElement('b');
      amount.textContent = note.amount + ' OCT';
      node.appendChild(amount);
      node.appendChild(document.createTextNode('amount hidden on chain'));
      if (entry.direction === 'in') {
        var claimed = null;
        try { claimed = localStorage.getItem('claimed:' + note.tx); } catch (error) { /* display only */ }
        var button = document.createElement('button');
        button.textContent = claimed ? 'claimed ' + claimed + ' OCT' : 'claim';
        button.disabled = !!claimed;
        button.setAttribute('data-claim', note.tx);
        node.appendChild(document.createElement('br'));
        node.appendChild(button);
      }
    } else {
      node.appendChild(document.createTextNode(entry.error ? 'rejected: ' + entry.error : entry.text));
    }
    var meta = document.createElement('span');
    meta.className = 'meta';
    meta.textContent = entry.direction === 'in'
      ? 'frame ' + entry.sequence + ' · epoch ' + entry.epoch
      : new Date(entry.time * 1000).toLocaleTimeString();
    node.appendChild(meta);
    chat.appendChild(node);
  });
  if (atBottom) chat.scrollTop = chat.scrollHeight;
}

async function poll() {
  for (;;) {
    try {
      if (state.contact && await receive()) await render();
    } catch (error) { /* transient read failure, retry on the next tick */ }
    await sleep(POLL_MS);
  }
}

async function start() {
  try {
    state.config = await (await fetch('/messenger-config.json')).json();
    state.session = await api('GET', '/wallet/session');
    if (!state.session.address) throw new Error('unlock your wallet in the main tab, then reload');
    state.me = state.session.address;
    $('wallet').textContent = state.me.slice(0, 10) + '…' + state.me.slice(-6);
    $('wallet').className = 'badge ok';
    $('address').textContent = state.me;
    await refreshMailbox();
    refreshEncrypted();
  } catch (error) {
    $('wallet').textContent = 'not connected';
    $('wallet').className = 'badge bad';
    $('mailbox').textContent = error.message;
  }
}

$('setup').addEventListener('click', setup);
$('connect').addEventListener('click', connect);
$('send').addEventListener('click', send);
$('pay').addEventListener('click', pay);
$('chat').addEventListener('click', function (event) {
  var tx = event.target && event.target.getAttribute && event.target.getAttribute('data-claim');
  if (tx) claim(tx, event.target);
});
$('text').addEventListener('keydown', function (event) { if (event.key === 'Enter') send(); });
start();
