'use strict';

const app = document.getElementById('app');
const panel = document.getElementById('panel');
const closeButton = document.getElementById('close-button');
const exportButton = document.getElementById('export-button');
const resetButton = document.getElementById('reset-button');
const exportStatus = document.getElementById('export-status');
const rangeSlider = document.getElementById('range-slider');
const rangeValue = document.getElementById('range-value');
const lockList = document.getElementById('lock-list');
const scaleSlider = document.getElementById('scale-slider');
const scaleValue = document.getElementById('scale-value');
const editorList = document.getElementById('editor-list');
const emptyMessage = document.getElementById('empty-message');
const resultCount = document.getElementById('result-count');

const scaleStorageKey = 'nt_imapviewer_ui_scale';
const defaultUiScale = 1;
let currentImaps = [];
let listLocked = false;
const heldImaps = new Set();
let rangeTimer;

function postNui(endpoint, payload = {}) {
  return fetch(`https://${GetParentResourceName()}/${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(payload)
  }).then((response) => {
    if (!response.ok) throw new Error(`NUI request failed: ${response.status}`);
    return response.json();
  });
}

function observedLabel(state) {
  if (state === 'loaded') return 'Active';
  if (state === 'unloaded') return 'Inactive';
  return 'State unknown';
}

function setExportStatus(message, state = '') {
  exportStatus.textContent = message || '';
  exportStatus.className = `export-status ${state}`.trim();
}

function createAction(label, className, row, targetState, selected) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `imap-action ${className}${selected ? ' selected' : ''}`;
  button.textContent = label;
  button.disabled = selected;

  button.setAttribute('aria-label', `Set ${row.hash} to ${targetState}`);
  button.addEventListener('click', () => {
    button.disabled = true;
    postNui('setImap', { hash: row.hash, state: targetState }).then((result) => {
      if (!result || result.ok === false) button.disabled = false;
    }).catch(() => { button.disabled = false; });
  });
  return button;
}

function setHeldLocal(hash, held) {
  const key = String(hash);
  if (held) heldImaps.add(key);
  else heldImaps.delete(key);

  const row = currentImaps.find((item) => String(item.hash) === key);
  if (row) row.held = held === true;
}

function syncHeldFromRows(rows) {
  rows.forEach((row) => setHeldLocal(row.hash, row.held === true));
}

function createHoldAction(row) {
  const hash = String(row.hash);
  const held = heldImaps.has(hash);
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `imap-action hold${held ? ' selected' : ''}`;
  button.textContent = '\u270B';
  button.setAttribute('aria-label', `${held ? 'Release' : 'Hold'} ${row.hash} during reset`);
  button.setAttribute('aria-pressed', String(held));
  button.title = held ? 'Held: Reset will leave this iMap unchanged' : 'Hold this iMap through Reset';
  button.addEventListener('click', () => {
    const nextHeld = !heldImaps.has(hash);
    setHeldLocal(hash, nextHeld);
    render();
    postNui('setHeld', { hash: row.hash, held: nextHeld }).then((result) => {
      if (!result || result.ok === false) {
        setHeldLocal(hash, !nextHeld);
        render();
      }
    }).catch(() => {
      setHeldLocal(hash, !nextHeld);
      render();
    });
  });
  return button;
}

function createRow(row) {
  const article = document.createElement('article');
  article.className = 'imap-row';

  const details = document.createElement('div');
  details.className = 'imap-details';
  const primary = document.createElement('span');
  primary.className = 'imap-hash';
  primary.textContent = row.hash;

  const meta = document.createElement('div');
  meta.className = 'imap-meta';
  const distance = document.createElement('span');
  distance.textContent = `${Number(row.distance).toFixed(1)} m`;
  meta.append(distance);

  const observed = document.createElement('span');
  observed.className = row.state === 'loaded' ? 'state-loaded' : (row.state === 'unloaded' ? 'state-unloaded' : '');
  observed.textContent = observedLabel(row.state);
  meta.append(observed);

  if (row.changed) {
    const changed = document.createElement('span');
    changed.className = 'state-changed';
    changed.textContent = `Override: ${row.configuredState}`;
    meta.append(changed);
  }

  if (row.name) {
    const name = document.createElement('span');
    name.className = 'imap-name';
    name.textContent = row.name;
    meta.append(name);
  }

  details.append(primary, meta);
  article.append(
    details,
    createAction('D', 'default', row, 'default', row.configuredState === 'default'),
    createAction('+', 'add', row, 'enabled', row.configuredState === 'enabled'),
    createAction('\u2212', 'remove', row, 'disabled', row.configuredState === 'disabled'),
    createHoldAction(row)
  );
  return article;
}

function render() {
  editorList.replaceChildren();
  const rows = currentImaps;

  rows.forEach((row) => editorList.append(createRow(row)));
  resultCount.textContent = `${rows.length} IMAP${rows.length === 1 ? '' : 's'} found`;
  emptyMessage.classList.toggle('visible', rows.length === 0);
}

function mergeLockedImaps(nextRows) {
  const byHash = new Map(nextRows.map((row) => [String(row.hash), row]));
  currentImaps = currentImaps.map((cached) => {
    const updated = byHash.get(String(cached.hash));
    return updated ? { ...cached, state: updated.state, configuredState: updated.configuredState, changed: updated.changed, held: updated.held === true } : cached;
  });
}

function setRange(value) {
  const range = Math.max(2, Math.min(50, Math.round(Number(value) || 10)));
  rangeSlider.value = range;
  rangeValue.textContent = `${range} m`;
}

function viewportScaleMaximum() {
  const widthScale = (window.innerWidth * 0.94) / panel.offsetWidth;
  const heightScale = (window.innerHeight * 0.94) / panel.offsetHeight;
  return Math.max(0.5, Math.floor((Math.min(2, widthScale, heightScale) + Number.EPSILON) / 0.05) * 0.05);
}

function applyScale(value) {
  const maximum = viewportScaleMaximum();
  let scale = Number(value);
  if (!Number.isFinite(scale)) scale = defaultUiScale;
  scale = Math.max(0.5, Math.min(maximum, Math.round(scale / 0.05) * 0.05));
  scaleSlider.max = maximum.toFixed(2);
  scaleSlider.value = scale.toFixed(2);
  scaleValue.textContent = `${Math.round(scale * 100)}%`;
  document.documentElement.style.setProperty('--ui-scale', scale);
  localStorage.setItem(scaleStorageKey, String(scale));
}

function applyPayload(payload, opening = false) {
  const rows = Array.isArray(payload.imaps) ? payload.imaps : [];

  if (opening) {
    listLocked = false;
    currentImaps = rows;
    heldImaps.clear();
    syncHeldFromRows(rows);
    lockList.checked = false;
    app.classList.add('visible');
    app.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => applyScale(localStorage.getItem(scaleStorageKey) || defaultUiScale));
  } else {
    if (listLocked) mergeLockedImaps(rows);
    else currentImaps = rows;
    syncHeldFromRows(rows);
  }

  setRange(payload.range);
  render();
}

window.addEventListener('message', (event) => {
  const payload = event.data || {};
  if (payload.action === 'open') {
    applyPayload(payload, true);
  } else if (payload.action === 'update') {
    applyPayload(payload, false);
  } else if (payload.action === 'settingState') {
    const row = currentImaps.find((item) => String(item.hash) === String(payload.hash));
    if (row) { row.configuredState = payload.state; row.changed = payload.changed === true; setHeldLocal(payload.hash, payload.held === true); render(); }
  } else if (payload.action === 'heldState') {
    setHeldLocal(payload.hash, payload.held === true);
    render();
  } else if (payload.action === 'close') {
    app.classList.remove('visible');
    app.setAttribute('aria-hidden', 'true');
  } else if (payload.action === 'exportResult') {
    exportButton.disabled = false;
    setExportStatus(payload.message || (payload.ok ? 'Config exported.' : 'Config export failed.'), payload.ok ? 'success' : 'error');
  } else if (payload.action === 'resetResult') {
    resetButton.disabled = false;
    setExportStatus(payload.message || (payload.ok ? 'List reset.' : 'Reset failed.'), payload.ok ? 'success' : 'error');
  }
});

rangeSlider.addEventListener('input', () => {
  setRange(rangeSlider.value);
  clearTimeout(rangeTimer);
  rangeTimer = setTimeout(() => postNui('setRange', { range: Number(rangeSlider.value) }), 80);
});
lockList.addEventListener('change', () => {
  listLocked = lockList.checked;
  if (!listLocked) {
    postNui('setRange', { range: Number(rangeSlider.value) }).catch(() => {});
  }
});
scaleSlider.addEventListener('input', () => applyScale(scaleSlider.value));

resetButton.addEventListener('click', () => {
  const rows = currentImaps;
  if (rows.length === 0) {
    setExportStatus('There are no displayed IMAPs to reset.', 'error');
    return;
  }

  const resetHashes = rows
    .filter((row) => !heldImaps.has(String(row.hash)))
    .map((row) => row.hash);
  if (resetHashes.length === 0) {
    setExportStatus('Every displayed iMap is held; nothing was reset.', 'success');
    return;
  }

  resetButton.disabled = true;
  const heldCount = rows.length - resetHashes.length;
  setExportStatus(heldCount > 0
    ? `Restoring displayed iMaps except ${heldCount} held...`
    : 'Restoring displayed iMaps to baseline...');
  postNui('resetImaps', { hashes: resetHashes }).then((result) => {
    if (!result || result.ok === false) {
      resetButton.disabled = false;
      setExportStatus('Could not request list reset.', 'error');
    }
  }).catch(() => {
    resetButton.disabled = false;
    setExportStatus('Could not request list reset.', 'error');
  });
});

exportButton.addEventListener('click', () => {
  exportButton.disabled = true;
  setExportStatus('Exporting merged iMap config...');
  postNui('exportConfig').catch(() => {
    exportButton.disabled = false;
    setExportStatus('Could not request config export.', 'error');
  });
});

closeButton.addEventListener('click', () => postNui('close'));
window.addEventListener('keydown', (event) => { if (event.key === 'Escape') postNui('close'); });
window.addEventListener('mousedown', (event) => {
  if (event.button === 2 && app.classList.contains('visible')) {
    event.preventDefault();
    postNui('cameraDragStart').catch(() => {});
  }
});
window.addEventListener('contextmenu', (event) => { if (app.classList.contains('visible')) event.preventDefault(); });
window.addEventListener('resize', () => { if (app.classList.contains('visible')) applyScale(scaleSlider.value); });

let readyAttempts = 0;
function announceReady() {
  postNui('ready').catch(() => {
    readyAttempts += 1;
    if (readyAttempts < 20) setTimeout(announceReady, 250);
  });
}
announceReady();
