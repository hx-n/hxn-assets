const MAX_BYTES = 64 * 1024 * 1024;
const MAX_BUFFERED = 128 * 1024 * 1024;
const MAX_JOBS = 16;

export function service(memory, address) {
  const contexts = new Map(), jobs = new Map();
  const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', {fatal: true});
  let buffered = 0, active = 0;
  const shared = typeof SharedArrayBuffer !== 'undefined' && memory.buffer instanceof SharedArrayBuffer;
  const words = () => new Int32Array(memory.buffer);
  const load = index => shared ? Atomics.load(words(), (address >>> 2) + index) >>> 0 : words()[(address >>> 2) + index] >>> 0;
  const store = (index, value) => { if (shared) Atomics.store(words(), (address >>> 2) + index, value); else words()[(address >>> 2) + index] = value; };
  function view(pointer, length) {
    if (!Number.isInteger(pointer) || !Number.isInteger(length) || pointer < 0 || length < 0 || pointer + length > memory.buffer.byteLength)
      throw new Error('invalid file request memory range');
    return new Uint8Array(memory.buffer, pointer, length);
  }
  function reserve(job, amount) {
    if (buffered + amount > MAX_BUFFERED) throw new Error('browser file buffer budget exceeded');
    buffered += amount; job.owned += amount;
  }
  function release(job, amount = job.owned) { buffered -= amount; job.owned -= amount; }
  function notify() {
    const now = (load(7) + 1) >>> 0; store(7, now);
    const wake = load(8);
    if (shared && wake) { Atomics.add(words(), wake >>> 2, 1); Atomics.notify(words(), wake >>> 2); }
  }
  function database(application) {
    return new Promise((resolve, reject) => {
      if (typeof indexedDB === 'undefined') { reject(new Error('IndexedDB is unavailable')); return; }
      let refused = false;
      const request = indexedDB.open('hxn-file:' + application, 1);
      request.onupgradeneeded = () => request.result.createObjectStore('values');
      request.onblocked = () => { refused = true; reject(new Error('IndexedDB upgrade is blocked')); };
      request.onerror = () => reject(request.error || new Error('IndexedDB open failed'));
      request.onsuccess = () => { if (refused) request.result.close(); else resolve(request.result); };
    });
  }
  async function transaction(context, mode, operate) {
    const db = await database(context.application);
    try {
      return await new Promise((resolve, reject) => {
        let tx;
        try { tx = db.transaction('values', mode, {durability: 'strict'}); }
        catch (error) { if (!(error instanceof TypeError)) throw error; tx = db.transaction('values', mode); }
        let result;
        tx.onabort = () => reject(tx.error || new Error('IndexedDB transaction aborted'));
        tx.onerror = () => {};
        tx.oncomplete = () => resolve(result);
        try { operate(tx.objectStore('values'), value => { result = value; }); }
        catch (error) { tx.abort(); reject(error); }
      });
    } finally { db.close(); }
  }
  async function fetchAsset(context, request, job) {
    const encoded = request.path.split('/').map(encodeURIComponent).join('/');
    const url = new URL(encoded, context.base);
    const controller = new AbortController(); job.abort = controller;
    const timer = setTimeout(() => controller.abort(), 30000);
    const chunks = []; let size = 0;
    try {
      const response = await fetch(url, {signal: controller.signal, credentials: 'same-origin'});
      if (!response.ok) throw new Error('asset fetch failed: HTTP ' + response.status);
      const reported = Number(response.headers.get('content-length'));
      if (Number.isFinite(reported) && reported > MAX_BYTES) throw new Error('asset exceeds the 64 MiB read limit');
      if (!response.body) return new Uint8Array();
      const reader = response.body.getReader();
      try {
        for (;;) {
          const {done, value} = await reader.read();
          if (done) break;
          if (size + value.byteLength > MAX_BYTES) throw new Error('asset exceeds the 64 MiB read limit');
          reserve(job, value.byteLength); size += value.byteLength; chunks.push(value);
        }
        reserve(job, size);
        const bytes = new Uint8Array(size); let at = 0;
        for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.byteLength; }
        release(job, size); return bytes;
      } finally { try { await reader.cancel(); } catch (_) {} }
    } finally { clearTimeout(timer); }
  }
  async function operate(context, request, job, input) {
    switch (request.operation) {
      case 'asset': return await fetchAsset(context, request, job);
      case 'read': {
        const value = await transaction(context, 'readonly', (store, done) => {
          const read = store.get('save/' + request.path); read.onsuccess = () => done(read.result);
        });
        if (!(value instanceof Uint8Array)) throw new Error('save was not found');
        if (value.byteLength > MAX_BYTES) throw new Error('save exceeds the read limit');
        reserve(job, value.byteLength); return value;
      }
      case 'write':
        await transaction(context, 'readwrite', store => store.put(input, 'save/' + request.path));
        return new Uint8Array();
      case 'delete':
      case 'deletePreference': {
        const key = request.operation === 'delete' ? 'save/' + request.path : 'pref/' + request.key;
        const found = await transaction(context, 'readwrite', (store, done) => {
          const read = store.getKey(key); read.onsuccess = () => { done(read.result !== undefined); store.delete(key); };
        });
        return new Uint8Array([found ? 1 : 0]);
      }
      case 'preference': {
        const value = await transaction(context, 'readonly', (store, done) => {
          const read = store.get('pref/' + request.key); read.onsuccess = () => done(read.result);
        });
        if (value !== undefined && (typeof value !== 'string' || encoder.encode(value).byteLength > 65536)) throw new Error('invalid stored preference');
        return encoder.encode(JSON.stringify({found: value !== undefined, value: value === undefined ? '' : value}));
      }
      case 'setPreference':
        if (typeof request.value !== 'string' || encoder.encode(request.value).byteLength > 65536) throw new Error('preference exceeds the 64 KiB limit');
        await transaction(context, 'readwrite', store => store.put(request.value, 'pref/' + request.key));
        return new Uint8Array();
      default: throw new Error('unknown file operation');
    }
  }
  function executeRequest(request) {
    switch (request.op) {
      case 'open': {
        if (contexts.size >= 256 || contexts.has(request.context)) throw new Error('browser file context limit exceeded');
        let base = new URL(request.assets || './assets/', import.meta.url);
        if (!['https:', 'http:'].includes(base.protocol) || base.username || base.password) throw new Error('asset base must be an HTTP(S) URL without credentials');
        if (!base.pathname.endsWith('/')) base.pathname += '/';
        contexts.set(request.context, {application: request.application, base}); return true;
      }
      case 'close': contexts.delete(request.context); return true;
      case 'start': {
        const context = contexts.get(request.context);
        if (!context) throw new Error('file context is closed');
        if (jobs.size >= MAX_JOBS || jobs.has(request.job)) throw new Error('too many pending browser file operations');
        const job = {owned: 0, done: false, data: null, error: null, abort: null};
        let input = null;
        if (request.operation === 'write') {
          if (request.length > MAX_BYTES) throw new Error('save exceeds the 64 MiB limit');
          reserve(job, request.length);
          try { input = new Uint8Array(view(request.address, request.length)); }
          catch (error) { release(job); throw error; }
        }
        jobs.set(request.job, job); active++;
        Promise.resolve().then(() => operate(context, request, job, input)).then(data => {
          if (!jobs.has(request.job)) return;
          if (request.operation !== 'asset' && request.operation !== 'read') { release(job); reserve(job, data.byteLength); }
          job.data = data;
        }).catch(error => { job.error = String(error?.message || error).slice(0, 4096); release(job); }).finally(() => {
          active--; job.done = true;
          if (jobs.has(request.job)) notify(); else release(job);
        });
        return true;
      }
      case 'status': {
        const job = jobs.get(request.job);
        if (!job) throw new Error('file request no longer exists');
        return {done: job.done, length: job.data?.byteLength || 0, error: job.error};
      }
      case 'take': {
        const job = jobs.get(request.job);
        if (!job || !job.done || job.error) throw new Error('file result is not ready');
        if (request.length !== job.data.byteLength) throw new Error('file result length changed');
        view(request.address, request.length).set(job.data);
        release(job); jobs.delete(request.job); return true;
      }
      case 'cancel': {
        const job = jobs.get(request.job);
        if (job) { jobs.delete(request.job); job.abort?.abort(); if (job.done) release(job); }
        return true;
      }
      default: throw new Error('unknown file bridge request');
    }
  }
  function execute() {
    let result;
    try {
      const bytes = view(load(2), load(3));
      if (bytes.byteLength > 1048576) throw new Error('file request is too large');
      // Decoding and request dispatch copy all guest input before acknowledgment.
      result = {ok: executeRequest(JSON.parse(decoder.decode(new Uint8Array(bytes))))};
    } catch (error) { result = {error: String(error?.message || error).slice(0,4096)}; }
    let reply = encoder.encode(JSON.stringify(result));
    if (reply.length > load(5)) reply = encoder.encode('{"error":"file reply exceeds its buffer"}');
    view(load(4), Math.min(reply.length, load(5))).set(reply.subarray(0,load(5)));
    store(6, reply.length); store(1, load(0));
    if (shared) Atomics.notify(words(), (address >>> 2) + 1);
  }
  async function serve() {
    let seen = load(1);
    for (;;) {
      const sent = load(0);
      if (sent !== seen) { execute(); seen = sent; await Promise.resolve(); continue; }
      // A blocking wait is safe only with no fetch/IDB callbacks awaiting this Worker.
      if (!active) Atomics.wait(words(), address >>> 2, seen | 0);
      else if (Atomics.waitAsync) await Atomics.waitAsync(words(), address >>> 2, seen | 0, 4).value;
      else await new Promise(resolve => setTimeout(resolve, 4));
    }
  }
  return {execute, serve};
}

export function start({memory, address, fail, serveMailbox = true}) {
  if (!serveMailbox) return service(memory, address).execute;
  const worker = new Worker(new URL(import.meta.url), {type: 'module'});
  worker.onerror = event => { const error = new Error('file agent: ' + event.message); if (fail) fail(error); else console.error(error); };
  worker.postMessage({memory, address});
  return worker;
}
if (typeof WorkerGlobalScope !== 'undefined' && globalThis instanceof WorkerGlobalScope) {
  self.onmessage = ({data}) => { service(data.memory, data.address).serve().catch(error => { throw error; }); };
}
