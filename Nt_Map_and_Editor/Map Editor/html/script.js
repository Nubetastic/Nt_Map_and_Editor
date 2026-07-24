'use strict';

const app = document.getElementById('app');
const panel = document.getElementById('panel');
const closeButton = document.getElementById('close-button');
const exportButton = document.getElementById('export-button');
const exportStatus = document.getElementById('export-status');
const rangeSlider = document.getElementById('range-slider');
const rangeValue = document.getElementById('range-value');
const scaleSlider = document.getElementById('scale-slider');
const scaleValue = document.getElementById('scale-value');
const imapList = document.getElementById('imap-list');
const emptyMessage = document.getElementById('empty-message');
const resultCount = document.getElementById('result-count');

const scaleStorageKey = 'nt_imapviewer_ui_scale';
const defaultUiScale = 1;
let currentImaps = [];
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

function stateLabel(state) {
  if (state === 'loaded') return 'Loaded';
  if (state === 'unloaded') return 'Unloaded';
  return 'State unknown';
}

function createAction(label, className, hash, enabled, disabled) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `imap-action ${className}`;
  button.textContent = label;
  button.disabled = disabled;
  button.setAttribute('aria-label', `${enabled ? 'Load' : 'Remove'} IMAP ${hash}`);
  button.addEventListener('click', () => {
    button.disabled = true;
    postNui('setImap', { hash, enabled })
      .then((result) => {
        if (!result || result.ok === false) button.disabled = false;
      })
      .catch(() => {
        button.disabled = false;
      });
  });
  return button;
}

function renderImaps() {
  imapList.replaceChildren();
  resultCount.textContent = `${currentImaps.length} IMAP${currentImaps.length === 1 ? '' : 's'} found`;
  emptyMessage.classList.toggle('visible', currentImaps.length === 0);

  const fragment = document.createDocumentFragment();

  currentImaps.forEach((imap) => {
    const row = document.createElement('article');
    row.className = 'imap-row';

    const details = document.createElement('div');
    details.className = 'imap-details';

    const hash = document.createElement('span');
    hash.className = 'imap-hash';
    hash.textContent = imap.hash;

    const meta = document.createElement('div');
    meta.className = 'imap-meta';

    const distance = document.createElement('span');
    distance.textContent = `${Number(imap.distance).toFixed(1)} m`;

    const state = document.createElement('span');
    state.className = imap.state === 'loaded'
      ? 'state-loaded'
      : (imap.state === 'unloaded' ? 'state-unloaded' : '');
    state.textContent = stateLabel(imap.state);

    meta.append(distance, state);

    if (imap.changed) {
      const changed = document.createElement('span');
      changed.className = 'state-changed';
      changed.textContent = `Override: ${imap.configuredState === 'loaded' ? 'Loaded' : 'Unloaded'}`;
      meta.append(changed);
    }

    if (imap.name) {
      const name = document.createElement('span');
      name.className = 'imap-name';
      name.textContent = imap.name;
      meta.append(name);
    }

    details.append(hash, meta);
    row.append(
      details,
      createAction('+', 'add', imap.hash, true, imap.state === 'loaded'),
      createAction('\u2212', 'remove', imap.hash, false, imap.state === 'unloaded')
    );
    fragment.append(row);
  });

  imapList.append(fragment);
}

function setRange(value) {
  const range = Math.max(2, Math.min(50, Math.round(Number(value) || 10)));
  rangeSlider.value = range;
  rangeValue.textContent = `${range} m`;
}

function viewportScaleMaximum() {
  const widthScale = (window.innerWidth * 0.94) / panel.offsetWidth;
  const heightScale = (window.innerHeight * 0.94) / panel.offsetHeight;
  const viewportMax = Math.min(2, widthScale, heightScale);
  return Math.max(0.5, Math.floor((viewportMax + Number.EPSILON) / 0.05) * 0.05);
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

function show(payload) {
  currentImaps = Array.isArray(payload.imaps) ? payload.imaps : [];
  setRange(payload.range);
  app.classList.add('visible');
  app.setAttribute('aria-hidden', 'false');
  requestAnimationFrame(() => applyScale(localStorage.getItem(scaleStorageKey) || defaultUiScale));
  renderImaps();
}

function hide() {
  app.classList.remove('visible');
  app.setAttribute('aria-hidden', 'true');
}

function setExportStatus(message, state = '') {
  exportStatus.textContent = message || '';
  exportStatus.className = `export-status ${state}`.trim();
}

window.addEventListener('message', (event) => {
  const payload = event.data || {};

  if (payload.action === 'open') {
    show(payload);
  } else if (payload.action === 'update') {
    currentImaps = Array.isArray(payload.imaps) ? payload.imaps : [];
    setRange(payload.range);
    renderImaps();
  } else if (payload.action === 'close') {
    hide();
  } else if (payload.action === 'exportResult') {
    exportButton.disabled = false;
    setExportStatus(payload.message || (payload.ok ? 'Config exported.' : 'Config export failed.'), payload.ok ? 'success' : 'error');
  }
});

rangeSlider.addEventListener('input', () => {
  setRange(rangeSlider.value);
  clearTimeout(rangeTimer);
  rangeTimer = setTimeout(() => {
    postNui('setRange', { range: Number(rangeSlider.value) });
  }, 80);
});

scaleSlider.addEventListener('input', () => applyScale(scaleSlider.value));
exportButton.addEventListener('click', () => {
  exportButton.disabled = true;
  setExportStatus('Exporting merged config...');
  postNui('exportConfig').catch(() => {
    exportButton.disabled = false;
    setExportStatus('Could not request config export.', 'error');
  });
});
closeButton.addEventListener('click', () => postNui('close'));

window.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    postNui('close');
  }
});

window.addEventListener('resize', () => {
  if (app.classList.contains('visible')) {
    applyScale(scaleSlider.value);
  }
});
