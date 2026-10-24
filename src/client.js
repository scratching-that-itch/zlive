/* zlive client — vanilla JS + morphdom (loaded via CDN by the host page).
 *
 * Two parts:
 *   1. window.LiveHooks — minimal hooks registry. Register named hooks with
 *      {mounted, updated, destroyed}; any element carrying data-lv-hook="<name>"
 *      gets its lifecycle driven by the view renderer.
 *   2. window.Live — the socket client: connect/join, full render on mount,
 *      morphdom patches, delegated [data-lv-click] events with incrementing
 *      refs, and reconnect with exponential backoff.
 *
 * Client-owned subtrees: an element carrying data-lv-ignore keeps its
 * children across patches — morphdom still morphs its attributes (and fires
 * the hook's `updated`), but never touches what is inside. That is how a
 * hook can host a canvas/SVG library (a chart) that draws its own DOM.
 */
(function () {
  'use strict';

  // ------------------------------------------------------------------
  // LiveHooks: hooks registry + lifecycle tracking
  // ------------------------------------------------------------------

  const registry = new Map(); // name -> {mounted?, updated?, destroyed?}
  const attached = new Map(); // element -> name

  function hookName(node) {
    if (node.nodeType !== 1) return null;
    const name = node.getAttribute('data-lv-hook');
    return name && registry.has(name) ? name : null;
  }

  function eachHook(node, fn) {
    const own = hookName(node);
    if (own) fn(node, own);
    if (node.querySelectorAll) {
      for (const el of node.querySelectorAll('[data-lv-hook]')) {
        const name = hookName(el);
        if (name) fn(el, name);
      }
    }
  }

  function mount(el, name) {
    if (attached.has(el)) return;
    attached.set(el, name);
    const impl = registry.get(name);
    if (impl.mounted) impl.mounted(el);
  }

  function destroy(el, name) {
    attached.delete(el);
    const impl = registry.get(name);
    if (impl.destroyed) impl.destroyed(el);
  }

  window.LiveHooks = {
    register(name, impl) {
      registry.set(name, impl);
      // mount matching elements that are already in the DOM
      document
        .querySelectorAll('[data-lv-hook="' + CSS.escape(name) + '"]')
        .forEach((el) => mount(el, name));
    },

    // lifecycle entry points used by the renderer / morphdom integration
    nodeAdded(node) { eachHook(node, mount); },
    nodeDiscarded(node) { eachHook(node, destroy); },
    elUpdated(el) {
      const name = attached.get(el);
      if (name && registry.get(name).updated) registry.get(name).updated(el);
    },
    teardown(node) { eachHook(node, destroy); },
  };

  // ------------------------------------------------------------------
  // Live: socket client
  // ------------------------------------------------------------------

  const state = {
    url: 'ws://127.0.0.1:9224/ws',
    topic: 'view:counter',
    socket: null,
    ref: 0,
    tree: null,
    attempt: 0,
    maxDelay: 8000,
    baseDelay: 500,
    // extra fields merged into the join payload (opts.join)
    join: null,
    // set on a version_mismatch error: reconnecting can't fix it
    fatal: false,
  };

  let container, logEl;

  function log(cls, text) {
    if (!logEl) return;
    const li = document.createElement('li');
    li.className = cls;
    li.textContent = text;
    logEl.appendChild(li);
    logEl.scrollTop = logEl.scrollHeight;
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  // render tree -> HTML: strings are statics (trusted markup, passed
  // through); objects are dynamic strings — {s: "..."} is text and gets
  // escaped, {html: "..."} is the server's explicit raw-HTML opt-in;
  // numbers and booleans are escaped scalars
  function flatten(node) {
    if (Array.isArray(node)) return node.map(flatten).join('');
    if (typeof node === 'string') return node;
    if (node !== null && typeof node === 'object') {
      if (node.html !== undefined) return node.html;
      return escapeHtml(node.s ?? '');
    }
    return escapeHtml(node);
  }

  function applyPatch(path, value) {
    const indices = path.split('.').map(Number);
    let node = state.tree;
    for (const i of indices.slice(0, -1)) node = node[i];
    node[indices[indices.length - 1]] = value;
  }

  // session token: stable per browser tab, so a reconnect (or reload) can
  // restore server-side view state instead of remounting fresh
  function sessionToken() {
    try {
      let token = sessionStorage.getItem('ziggy.session');
      if (!token) {
        token = crypto.randomUUID();
        sessionStorage.setItem('ziggy.session', token);
      }
      return token;
    } catch {
      return 'anon-' + Math.random().toString(36).slice(2);
    }
  }

  function send(event, payload) {
    if (!state.socket || state.socket.readyState !== WebSocket.OPEN) return null;
    const ref = ++state.ref;
    state.socket.send(JSON.stringify({
      version: 2, type: 'publish', topic: state.topic,
      event: event, payload: payload ?? null, ref: ref,
    }));
    log('sent', '-> #' + ref + ' ' + event);
    return ref;
  }

  function renderFull() {
    // replacing innerHTML doesn't fire morphdom discard callbacks,
    // so tear hooks down explicitly before dropping the old DOM
    window.LiveHooks.teardown(container);
    container.innerHTML = flatten(state.tree);
    window.LiveHooks.nodeAdded(container);
  }

  function morph() {
    window.morphdom(container, '<div>' + flatten(state.tree) + '</div>', {
      childrenOnly: true,
      onNodeAdded: (node) => window.LiveHooks.nodeAdded(node),
      onNodeDiscarded: (node) => window.LiveHooks.nodeDiscarded(node),
      onElUpdated: (el) => window.LiveHooks.elUpdated(el),
      // data-lv-ignore: attributes morph (the hook sees the new spec via
      // onElUpdated above), but the children belong to client code
      onBeforeElChildrenUpdated: (el) => !el.hasAttribute('data-lv-ignore'),
    });
  }

  function handleMessage(ev) {
    const env = JSON.parse(ev.data);
    log('recv', '<- #' + (env.ref ?? '-') + ' ' + env.type + ':' + env.event);
    if (env.type === 'err') {
      log('err', '   reason: ' + env.payload.reason);
      if (env.event === 'version_mismatch') {
        state.fatal = true;
        log('err', 'protocol version mismatch (server saw version ' +
                   (env.payload.version ?? '?') + '); giving up');
      }
      return;
    }
    if (env.event === 'render') {
      state.tree = env.payload;
      renderFull();
      return;
    }
    if (env.event === 'patch') {
      for (const [path, value] of Object.entries(env.payload)) {
        applyPatch(path, value);
      }
      morph();
    }
  }

  function backoffDelay() {
    const exp = state.baseDelay * 2 ** state.attempt;
    return Math.min(state.maxDelay, exp) + Math.floor(Math.random() * 250);
  }

  function connect() {
    const socket = new WebSocket(state.url);
    state.socket = socket;

    socket.addEventListener('open', () => {
      state.attempt = 0;
      log('sys', 'connected; joining ' + state.topic);
      // opts.join lets a page carry its own fields (a room id, a tenant)
      // into the mount: the server sees them on the join payload.
      send('join', { session: sessionToken(), ...state.join });
    });

    socket.addEventListener('message', handleMessage);

    socket.addEventListener('close', () => {
      if (state.fatal) {
        log('sys', 'fatal error; not reconnecting');
        return;
      }
      const wait = backoffDelay();
      state.attempt += 1;
      log('sys', 'disconnected; reconnecting in ' + wait + 'ms (attempt ' + state.attempt + ')');
      setTimeout(connect, wait);
    });

    socket.addEventListener('error', () => {
      socket.close();
    });
  }

  window.Live = {
    start(opts) {
      container = document.getElementById(opts.container);
      logEl = document.getElementById(opts.log);
      if (opts.url) state.url = opts.url;
      if (opts.topic) state.topic = opts.topic;
      if (opts.join) state.join = opts.join;

      // delegated [data-lv-click] events -> send event with a fresh ref;
      // data-lv-value identifies which item was clicked, data-lv-payload
      // (JSON) carries arbitrary arguments
      container.addEventListener('click', (ev) => {
        const el = ev.target.closest('[data-lv-click]');
        if (!el || !container.contains(el)) return;
        let payload = null;
        const raw = el.getAttribute('data-lv-payload');
        if (raw) {
          try { payload = JSON.parse(raw); } catch { payload = null; }
        }
        const value = el.getAttribute('data-lv-value');
        if (value !== null) payload = { id: el.id, value };
        send(el.getAttribute('data-lv-click'), payload);
      });

      // form fields: [data-lv-change] elements emit on every input/change
      const onFieldChange = (ev) => {
        const el = ev.target.closest('[data-lv-change]');
        if (!el || !container.contains(el)) return;
        const value = el.type === 'checkbox' ? el.checked : el.value;
        send(el.getAttribute('data-lv-change'), { id: el.id, value });
      };
      container.addEventListener('input', onFieldChange);
      container.addEventListener('change', onFieldChange);

      connect();
    },

    // demo helper: drop the socket to exercise reconnect + hook teardown
    disconnect() { if (state.socket) state.socket.close(); },
    send,
  };
})();
