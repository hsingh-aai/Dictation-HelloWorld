// The only surface the renderer can reach. No key, no Node, no arbitrary IPC.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('dictation', {
  transcribe: (audio, config) => ipcRenderer.invoke('transcribe', { audio, config }),
  paste: (text) => ipcRenderer.invoke('paste', text),
  defaults: () => ipcRenderer.invoke('defaults'),
  permissions: () => ipcRenderer.invoke('permissions'),
  requestAccessibility: () => ipcRenderer.invoke('request-accessibility'),
  warm: () => ipcRenderer.invoke('warm'),
  setState: (state) => ipcRenderer.send('state', state),
  hide: () => ipcRenderer.send('hide'),
  onHotkey: (fn) => ipcRenderer.on('hotkey', () => fn()),
  onTrigger: (fn) => ipcRenderer.on('trigger', (_e, action) => fn(action)),
});
