const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

function settingOn(key, fallback = "0") {
  const v = state.settings[key];
  const use = v == null || v === "" ? fallback : String(v);
  return use !== "0" && use !== "false";
}

function settingVal(key, fallback = "") {
  const v = state.settings[key];
  return v == null || v === "" ? fallback : String(v);
}

async function persistSettings(form, silent) {
  if (!form) return;
  const payload = formObj(form);
  delete payload.preset;
  delete payload.sig_name;
  delete payload.sig_body;
  await api("/api/settings", { method: "POST", body: payload });
  state.settings = await api("/api/settings");
  if (!silent) render();
}

async function persistSignatureEditor() {
  if (state.view !== "settings" || state.settingsPane !== "signatures" || !state.signatureId) return;
  const name = $("[name=sig_name]")?.value;
  const body = $("[name=sig_body]")?.value;
  if (name == null) return;
  await api(`/api/signatures/${state.signatureId}`, { method: "POST", body: { name, body } });
  state.signatures = await api("/api/signatures");
  const row = state.signatures.find((s) => s.id === state.signatureId);
  const item = $(`.sig-item[data-sig-id="${state.signatureId}"]`);
  if (item && row) item.textContent = `${row.name}${row.is_default ? " ★" : ""}`;
}

function notifyNewMail(added) {
  if (!added || !settingOn("notify_new_mail", "1")) return;
  if (!(window.Notification && Notification.permission === "granted")) return;
  new Notification("Praecipe", { body: `${added} new message${added === 1 ? "" : "s"}` });
}

let mailPollId = null;
let mailPollSec = null;

async function pollMail() {
  try {
    const out = await api("/api/mail/sync", { method: "POST", body: {} });
    await loadMail();
    notifyNewMail(out.added);
    if (state.view === "mail") render();
  } catch {}
}

function startMailPoll() {
  const sec = Number(settingVal("check_interval", "120"));
  if (mailPollId && mailPollSec === sec) return;
  if (mailPollId) {
    clearInterval(mailPollId);
    mailPollId = null;
  }
  mailPollSec = sec;
  if (!sec || sec <= 0) return;
  mailPollId = setInterval(pollMail, sec * 1000);
}

async function waitForOauth(oauthState) {
  const deadline = Date.now() + 900000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1200));
    const st = await api(`/api/oauth/status?state=${encodeURIComponent(oauthState)}`);
    if (st.status === "ok") return st;
    if (st.status === "error") throw new Error(st.error || "Sign-in failed");
  }
  throw new Error("Sign-in timed out. Try again.");
}

function fmtDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso).slice(0, 16);
  return d.toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
}

function day(iso) {
  return String(iso || "").slice(0, 10);
}

function localDay(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
    body: opts.body && typeof opts.body !== "string" ? JSON.stringify(opts.body) : opts.body,
  });
  const ctype = res.headers.get("content-type") || "";
  if (!ctype.includes("json")) {
    if (!res.ok) throw new Error(res.statusText);
    return res;
  }
  const text = await res.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; }
  catch { data = { error: text }; }
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

async function filesToPayload(fileList) {
  const out = [];
  for (const f of [...(fileList || [])]) {
    const data = await new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result).split(",")[1] || "");
      r.onerror = reject;
      r.readAsDataURL(f);
    });
    out.push({ filename: f.name, mime: f.type || "application/octet-stream", data });
  }
  return out;
}

const state = {
  view: "mail",
  folder: "INBOX",
  filter: null,
  folders: [],
  smart: { client: 0, eservice: 0, court: 0, client_unseen: 0, eservice_unseen: 0, court_unseen: 0 },
  mail: [],
  selectedMail: null,
  message: null,
  extract: null,
  matters: [],
  events: [],
  time: [],
  notes: [],
  files: [],
  contacts: [],
  catalog: [],
  settings: {},
  timer: null,
  month: new Date(),
  calMode: "month",
  status: "",
  query: "",
  compose: null,
  settingsPane: "general",
  signatures: [],
  signatureId: null,
  accounts: [],
  providers: [],
};

function matterLabel(id) {
  const m = state.matters.find((x) => x.id === id);
  if (!m) return "Unassigned";
  return m.case_no ? `${m.case_no} — ${m.style}` : m.style;
}

function matterSelect(name, selected, extra = "") {
  const opts = [`<option value="">${extra || "Matter"}</option>`]
    .concat(state.matters.map((m) =>
      `<option value="${m.id}" ${String(selected) === String(m.id) ? "selected" : ""}>${esc(matterLabel(m.id))}</option>`
    ));
  return `<select name="${name}">${opts.join("")}</select>`;
}

async function refreshCore() {
  const [matters, events, time, settings, catalog, folders, smart, signatures, accounts, providers] = await Promise.all([
    api("/api/matters"),
    api("/api/events"),
    api("/api/time"),
    api("/api/settings"),
    api("/api/deadlines/catalog"),
    api("/api/mail/folders"),
    api("/api/mail/smart"),
    api("/api/signatures"),
    api("/api/accounts"),
    api("/api/accounts/providers"),
  ]);
  state.matters = matters;
  state.events = events;
  state.time = time;
  state.settings = settings;
  state.catalog = catalog;
  state.folders = folders;
  state.smart = smart;
  state.signatures = signatures;
  state.accounts = accounts;
  state.providers = providers;
  if (!state.signatureId || !signatures.some((s) => s.id === state.signatureId)) {
    const def = signatures.find((s) => s.is_default) || signatures[0];
    state.signatureId = def ? def.id : null;
  }
  state.timer = time.find((t) => t.running) || null;
  renderTimer();
  renderUnread();
  renderSidebar();
  startMailPoll();
}

function renderTimer() {
  const chip = $("#timer-chip");
  if (!state.timer) {
    chip.classList.add("hidden");
    chip.textContent = "";
    return;
  }
  chip.classList.remove("hidden");
  const start = new Date(state.timer.started_at);
  const mins = Math.max(0, Math.round((Date.now() - start.getTime()) / 60000));
  chip.textContent = `Recording ${mins} min`;
}

function renderUnread() {
  const n = state.folders.reduce((s, f) => s + (f.unseen || 0), 0)
    + state.mail.filter((m) => !m.seen && m.folder === state.folder).length;
  const unseen = Math.max(
    n,
    state.mail.filter((m) => !m.seen).length,
    state.folders.reduce((s, f) => s + Number(f.unseen || 0), 0),
  );
  const chip = $("#unread-chip");
  if (chip) {
    if (unseen) {
      chip.classList.remove("hidden");
      chip.textContent = `${unseen} unread`;
    } else {
      chip.classList.add("hidden");
    }
  }
}

function setStatus(msg, isError) {
  state.status = msg;
  const el = $("#flash");
  if (el) {
    el.textContent = msg;
    el.className = isError ? "error" : "ok";
  }
}

function render() {
  const app = $("#app");
  const views = {
    mail: renderMail,
    matters: renderMatters,
    docket: renderDocket,
    time: renderTime,
    notes: renderNotes,
    files: renderFiles,
    rules: renderRules,
    settings: renderSettings,
    contacts: renderContacts,
  };
  app.innerHTML = (views[state.view] || renderMail)();
  bindView();
  renderSidebar();
}

function folderRoleLabel(f) {
  const name = f.name || "";
  if (f.role === "inbox" || name.toUpperCase() === "INBOX") return "Inbox";
  if (f.role === "sent" || name === "SENT") return "Sent";
  if (f.role === "drafts" || name === "DRAFTS") return "Drafts";
  if (f.role === "trash") return "Deleted";
  if (f.role === "junk") return "Junk";
  return name;
}

function displayName(addr) {
  const s = String(addr || "");
  const named = s.match(/^"?([^"<]+)"?\s*<.+>$/);
  if (named) return named[1].trim();
  const email = s.match(/[\w.+-]+@[\w.-]+/);
  return email ? email[0] : s || "Unknown";
}

function shortDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso).slice(0, 10);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) {
    return d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  }
  if (d.getFullYear() === now.getFullYear()) {
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "2-digit" });
}

function labelPills(labels) {
  const names = { client: "Client", eservice: "eService", court: "Court" };
  return (labels || []).map((k) => `<span class="pill ${esc(k)}">${names[k] || k}</span>`).join("");
}

function mailboxTitle() {
  if (state.filter === "client") return "Client";
  if (state.filter === "eservice") return "eService";
  if (state.filter === "court") return "Court";
  return folderRoleLabel({ name: state.folder });
}

function renderSidebar() {
  const el = $("#sidebar");
  if (!el) return;
  const s = state.smart || {};
  const fav = [
    { name: "INBOX", label: "Inbox" },
    { name: "DRAFTS", label: "Drafts" },
    { name: "SENT", label: "Sent" },
  ];
  const extras = (state.folders || []).filter((f) => !["INBOX", "SENT", "DRAFTS"].includes((f.name || "").toUpperCase()) && f.role !== "junk");
  const practice = [
    ["docket", "Calendar"],
    ["contacts", "People"],
    ["matters", "Matters"],
    ["time", "Time"],
    ["notes", "Notes"],
    ["files", "Files"],
    ["rules", "Rules"],
    ["settings", "Settings"],
  ];
  const favBtns = fav.map((f) => {
    const rec = (state.folders || []).find((x) => (x.name || "").toUpperCase() === f.name) || {};
    const on = state.view === "mail" && !state.filter && (state.folder || "").toUpperCase() === f.name;
    return `<button type="button" data-folder="${f.name}" class="${on ? "active" : ""}">${f.label}<span class="count">${rec.unseen || ""}</span></button>`;
  }).join("");
  const smartBtns = [
    ["client", "Client", s.client_unseen || s.client],
    ["eservice", "eService", s.eservice_unseen || s.eservice],
    ["court", "Court", s.court_unseen || s.court],
  ].map(([id, label, n]) => `
    <button type="button" data-filter="${id}" class="${state.view === "mail" && state.filter === id ? "active" : ""}">
      <span class="dot-swatch ${id}"></span>${label}<span class="count">${n || ""}</span>
    </button>`).join("");
  const folderBtns = extras.map((f) => `
    <button type="button" data-folder="${esc(f.name)}" class="${state.view === "mail" && !state.filter && state.folder === f.name ? "active" : ""}">
      ${esc(folderRoleLabel(f))}<span class="count">${f.unseen || ""}</span>
    </button>`).join("");
  const pracBtns = practice.map(([id, label]) =>
    `<button type="button" data-view="${id}" class="${state.view === id ? "active" : ""}">${label}</button>`
  ).join("");
  el.innerHTML = `
    <div class="group">Favorites</div>
    ${favBtns}
    <div class="group">Filters</div>
    ${smartBtns}
    ${folderBtns ? `<div class="group">Mailboxes</div>${folderBtns}` : ""}
    <div class="group">Practice</div>
    ${pracBtns}
  `;
  $$("[data-folder]", el).forEach((btn) => {
    btn.addEventListener("click", async () => {
      state.view = "mail";
      state.filter = null;
      state.folder = btn.dataset.folder;
      state.selectedMail = null;
      state.message = null;
      await loadMail();
      render();
    });
  });
  $$("[data-filter]", el).forEach((btn) => {
    btn.addEventListener("click", async () => {
      state.view = "mail";
      state.filter = btn.dataset.filter;
      state.selectedMail = null;
      state.message = null;
      await loadMail();
      render();
    });
  });
  $$("[data-view]", el).forEach((btn) => {
    btn.addEventListener("click", async () => {
      state.view = btn.dataset.view;
      state.filter = null;
      if (state.view === "notes") state.notes = await api("/api/notes");
      if (state.view === "files") state.files = await api("/api/files");
      if (state.view === "contacts") state.contacts = await api("/api/contacts");
      render();
    });
  });
}

function renderMail() {
  const items = state.mail.map((m) => `
    <article class="list-item ${state.selectedMail === m.id ? "active" : ""} ${m.seen ? "" : "unread"} ${m.flagged ? "flagged" : ""}" data-id="${m.id}">
      <span class="unread-dot"></span>
      <div class="sender">${esc(displayName(m.from_addr))}</div>
      <div class="when">${esc(shortDate(m.sent_at))}</div>
      <h3>${esc(m.subject || "(no subject)")}</h3>
      ${settingOn("show_preview", "1") ? `<p>${esc(m.snippet || "")}</p>` : ""}
      <div class="pills">${labelPills(m.labels)}${m.has_attachments ? '<span class="pill">Att</span>' : ""}</div>
    </article>`).join("");
  const msg = state.message;
  let reading = `<div class="empty">Select a message. Press N for a new email, or Send/Receive after IMAP is set.</div>`;
  if (msg) {
    const ex = state.extract;
    const suggest = ex ? `
      <div class="suggest">
        <h2>Docket &amp; service</h2>
        ${(ex.events || []).length ? `<ul>${ex.events.map((e, i) =>
          `<li>${esc(e.title)} <span class="meta">${esc(e.context || "")}</span>
           <button data-add-event="${i}">Add to calendar</button></li>`).join("")}</ul>` : "<p class='meta'>No dates found in this message.</p>"}
        ${(ex.urls || []).length ? `<ul>${ex.urls.map((u, i) =>
          `<li>${u.service_likely ? '<span class="badge">service</span>' : ""}
           <a href="${esc(u.url)}" target="_blank" rel="noopener">${esc(u.url)}</a>
           <button data-dl="${i}">Download to matter</button></li>`).join("")}</ul>` : ""}
        ${(ex.deadlines || []).length ? `<ul>${ex.deadlines.map((d, i) =>
          `<li>${esc(d.title)} ${d.trigger ? "(" + esc(d.trigger) + ")" : ""}
           <button data-add-deadline="${i}">Compute &amp; docket</button></li>`).join("")}</ul>` : ""}
      </div>` : "";
    const htmlFrame = msg.body_html
      ? `<iframe class="mail-html" sandbox></iframe>`
      : `<div class="mail-body">${esc(msg.body_text || "")}</div>`;
    reading = `
      <div class="toolbar cmd">
        <button id="btn-reply">Reply</button>
        <button id="btn-reply-all">Reply All</button>
        <button id="btn-forward">Forward</button>
        <button id="btn-delete">Delete</button>
        <button id="btn-unread">Unread</button>
        <button id="btn-flag">${msg.flagged ? "Unflag" : "Flag"}</button>
        <button id="btn-timer">${state.timer ? "Stop timer" : "Start timer"}</button>
        <button id="btn-note-mail">Note</button>
      </div>
      <form class="filebill" id="filebill">
        <h2>File &amp; Bill</h2>
        ${fileBillFields(msg)}
        <button type="submit" class="primary" id="btn-file-bill">Do all checked</button>
        <span id="filebill-status"></span>
      </form>
      <div class="reading">
        <div class="pills">${labelPills(msg.labels)}</div>
        <div class="meta">${esc(msg.from_addr)} → ${esc(msg.to_addr)}${msg.cc_addr ? " · Cc " + esc(msg.cc_addr) : ""} · ${esc(fmtDate(msg.sent_at))}</div>
        <h1>${esc(msg.subject)}</h1>
        ${(msg.attachments || []).map((a) => `<a class="badge file-link" href="/api/attachments/${a.id}">${esc(a.filename)}</a>`).join("")}
        ${suggest}
        ${htmlFrame}
      </div>`;
  }
  return `
    <div class="split mail">
      <div class="list">
        <div class="toolbar">
          <strong>${esc(mailboxTitle())}</strong>
          <span id="flash" class="${/fail|error/i.test(state.status) ? "error" : "ok"}">${esc(state.status)}</span>
        </div>
        ${items || `<div class="empty">No messages.</div>`}
      </div>
      <div class="pane">${reading}</div>
    </div>`;
}

function confClass(n) {
  if (n >= 75) return "hi";
  if (n >= 45) return "mid";
  return "lo";
}

function fileBillFields(msg) {
  const matches = msg.matches || [];
  const assigned = msg.matter_id;
  const top = matches[0];
  const selected = assigned || (top && top.confidence >= 45 ? top.matter_id : "");
  const types = msg.doc_types || [["correspondence", "Correspondence"]];
  const guessed = msg.doc_type || "correspondence";
  const client = msg.client_email || (top && top.client_email) || "";
  const matterOpts = (matches.length ? matches : state.matters.map((m) => ({
    matter_id: m.id, label: matterLabel(m.id), confidence: m.id === assigned ? 100 : 0, reasons: [],
    client_email: m.client_email || "",
  }))).map((m) => {
    const conf = m.confidence != null ? m.confidence : "";
    const mark = conf !== "" ? ` (${conf}%)` : "";
    return `<option value="${m.matter_id}" ${String(selected) === String(m.matter_id) ? "selected" : ""} data-client="${esc(m.client_email || "")}">${esc(m.label || matterLabel(m.matter_id))}${mark}</option>`;
  });
  const rest = state.matters.filter((m) => !matches.some((x) => x.matter_id === m.id));
  rest.forEach((m) => {
    matterOpts.push(`<option value="${m.id}" ${String(selected) === String(m.id) ? "selected" : ""} data-client="${esc(m.client_email || "")}">${esc(matterLabel(m.id))}</option>`);
  });
  const why = (matches.find((m) => String(m.matter_id) === String(selected)) || top);
  const whyText = why ? `${why.confidence}% — ${(why.reasons || []).join("; ") || "best guess"}` : "Pick a matter. Confidence is a guess, not a filing decision.";
  return `
    <label class="fb-matter">Matter
      <select name="matter_id" id="fb-matter">${matterOpts.join("")}</select>
      <span class="conf ${confClass(why ? why.confidence : 0)}" id="fb-conf">${esc(whyText)}</span>
    </label>
    <label class="check"><input type="checkbox" name="connect" checked> Connect this message to the matter</label>
    <label class="check"><input type="checkbox" name="save" checked> Save attachments to the matter folder</label>
    <label>Document type
      <select name="doc_type">${types.map((t) => {
        const id = Array.isArray(t) ? t[0] : t.id;
        const label = Array.isArray(t) ? t[1] : t.title;
        return `<option value="${esc(id)}" ${id === guessed ? "selected" : ""}>${esc(label)}</option>`;
      }).join("")}</select>
    </label>
    <label class="check"><input type="checkbox" name="download_urls" ${(msg.extract_urls || state.extract?.urls || []).some((u) => u.service_likely) ? "checked" : ""}> Download service documents from URLs into that folder</label>
    <label class="check"><input type="checkbox" name="email_client"> Email the client</label>
    <label>Client email <input name="client_email" id="fb-client" value="${esc(client)}" placeholder="set on the matter if blank"></label>
    <label class="check"><input type="checkbox" name="time" checked> Time entry</label>
    <label>Minutes <input name="minutes" type="number" step="0.1" value="${state.timer ? "" : "12"}" placeholder="timer if running"></label>
    <label>Activity <input name="activity" value="email"></label>
  `;
}

function renderMatters() {
  const rows = state.matters.map((m) => `
    <tr data-edit-matter="${m.id}">
      <td>${esc(m.case_no)}</td>
      <td>${esc(m.style)}</td>
      <td>${esc(m.county)}</td>
      <td>${esc(m.status)}</td>
      <td>${m.rate ? "$" + m.rate : ""}</td>
    </tr>`).join("");
  return `
    <div class="pane">
      <div class="toolbar">
        <strong>Matters</strong>
        <button id="btn-new-matter" class="primary">New matter</button>
      </div>
      <table>
        <thead><tr><th>Case</th><th>Style</th><th>County</th><th>Status</th><th>Rate</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

function renderDocket() {
  const y = state.month.getFullYear();
  const m = state.month.getMonth();
  const first = new Date(y, m, 1);
  const start = new Date(first);
  start.setDate(1 - first.getDay());
  const cells = [];
  for (let i = 0; i < 42; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    const key = localDay(d);
    const evs = state.events.filter((e) => day(e.start_at) === key);
    cells.push(`<div class="day ${d.getMonth() !== m ? "out" : ""}" data-day="${key}">
      <strong>${d.getDate()}</strong>
      ${evs.map((e) => `<span class="ev ${esc(e.event_type)}">${e.all_day ? "" : esc(String(e.start_at).slice(11, 16) + " ")}${esc(e.title)}</span>`).join("")}
    </div>`);
  }
  const weekStart = new Date(state.month);
  weekStart.setDate(state.month.getDate() - state.month.getDay());
  const weekCols = [];
  for (let i = 0; i < 7; i++) {
    const d = new Date(weekStart);
    d.setDate(weekStart.getDate() + i);
    const key = localDay(d);
    const evs = state.events.filter((e) => day(e.start_at) === key);
    weekCols.push(`<div class="col" data-day="${key}"><strong>${d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" })}</strong>
      ${evs.map((e) => `<span class="ev ${esc(e.event_type)}">${e.all_day ? "all day" : esc(String(e.start_at).slice(11, 16))} ${esc(e.title)}</span>`).join("")}</div>`);
  }
  const upcoming = [...state.events].sort((a, b) => String(a.start_at).localeCompare(String(b.start_at)))
    .filter((e) => day(e.start_at) >= localDay(new Date()))
    .slice(0, 24)
    .map((e) => `<li><strong>${esc(fmtDate(e.start_at))}</strong> · ${esc(e.title)}
      <span class="meta">${esc(matterLabel(e.matter_id))} ${esc(e.rule_cite || "")}</span>
      <button data-del-event="${e.id}">Remove</button></li>`).join("");
  return `
    <div class="split">
      <div class="pane">
        <div class="toolbar">
          <button id="prev-month">‹</button>
          <strong>${state.month.toLocaleString(undefined, { month: "long", year: "numeric" })}</strong>
          <button id="next-month">›</button>
          <button id="cal-month" class="${state.calMode === "month" ? "primary" : ""}">Month</button>
          <button id="cal-week" class="${state.calMode === "week" ? "primary" : ""}">Week</button>
          <a class="btn" href="/api/calendar.ics">Export .ics</a>
          <button id="btn-new-event" class="primary">New event</button>
        </div>
        ${state.calMode === "week" ? `<div class="week">${weekCols.join("")}</div>` : `<div class="month">
          ${["Sun","Mon","Tue","Wed","Thu","Fri","Sat"].map((d) => `<div class="dow">${d}</div>`).join("")}
          ${cells.join("")}
        </div>`}
      </div>
      <div class="side stack">
        <h2 style="font-family:var(--serif);margin:0">Upcoming</h2>
        <ul>${upcoming || "<li class='meta'>Nothing docketed.</li>"}</ul>
      </div>
    </div>`;
}

function renderTime() {
  const rows = state.time.map((t) => `
    <tr>
      <td>${esc(fmtDate(t.started_at))}</td>
      <td>${esc(matterLabel(t.matter_id))}</td>
      <td>${esc(t.activity)}</td>
      <td>${esc(t.description)}</td>
      <td>${t.running ? "running" : t.minutes}</td>
      <td>${t.rate ? "$" + (t.rate * (t.minutes || 0) / 60).toFixed(2) : ""}</td>
      <td>${t.running ? "" : `<button data-billed="${t.id}" data-on="${t.billed ? 0 : 1}">${t.billed ? "Billed" : "Mark billed"}</button>`}</td>
    </tr>`).join("");
  return `
    <div class="pane">
      <div class="toolbar">
        <strong>Time</strong>
        <button id="btn-add-time">Manual entry</button>
        <button id="btn-timer">${state.timer ? "Stop timer" : "Start timer"}</button>
        <a class="btn" href="/api/time.csv">Export CSV</a>
      </div>
      <table>
        <thead><tr><th>When</th><th>Matter</th><th>Activity</th><th>Description</th><th>Minutes</th><th>Fee</th><th></th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

function renderNotes() {
  const cards = state.notes.map((n) => `
    <article class="list-item" data-edit-note="${n.id}">
      <div class="meta">${esc(matterLabel(n.matter_id))} · ${esc(fmtDate(n.updated_at))}</div>
      <h3>${esc(n.title)}</h3>
      <p>${esc((n.body || "").slice(0, 280))}</p>
    </article>`).join("");
  return `
    <div class="pane">
      <div class="toolbar">
        <strong>Notes</strong>
        <button id="btn-new-note" class="primary">New note</button>
      </div>
      ${cards || `<div class="empty">No notes yet.</div>`}
    </div>`;
}

function renderFiles() {
  const rows = state.files.map((f) => `
    <tr>
      <td><a class="file-link" href="/api/files/${f.id}/download">${esc(f.filename)}</a></td>
      <td>${esc(f.doc_type || "")}</td>
      <td>${esc(matterLabel(f.matter_id))}</td>
      <td>${esc(f.source)}</td>
      <td class="meta">${esc(f.path)}</td>
      <td>${esc(fmtDate(f.created_at))}</td>
    </tr>`).join("");
  return `
    <div class="pane">
      <div class="toolbar">
        <strong>Matter files</strong>
        ${matterSelect("upload_matter", "", "Upload to matter")}
        <input id="upload-files" type="file" multiple>
        <button id="btn-upload" type="button">Upload</button>
      </div>
      <table>
        <thead><tr><th>File</th><th>Type</th><th>Matter</th><th>Source</th><th>Path</th><th>When</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

function renderContacts() {
  const rows = state.contacts.map((c) => `
    <tr data-edit-contact="${c.id}">
      <td>${esc(c.name)}</td>
      <td>${esc(c.email)}</td>
      <td>${esc(c.phone)}</td>
      <td>${esc(c.firm)}</td>
      <td>${esc(matterLabel(c.matter_id))}</td>
    </tr>`).join("");
  return `
    <div class="pane">
      <div class="toolbar">
        <strong>People</strong>
        <button id="btn-new-contact" class="primary">New contact</button>
      </div>
      <table>
        <thead><tr><th>Name</th><th>Email</th><th>Phone</th><th>Firm</th><th>Matter</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

function renderRules() {
  const opts = state.catalog.map((r) => `<option value="${esc(r.id)}">${esc(r.title)}</option>`).join("");
  const rows = state.catalog.filter((r) => r.id !== "custom").map((r) => `
    <tr>
      <td>${esc(r.title)}</td>
      <td>${esc(r.rule)}</td>
      <td>${r.days ?? "—"} ${esc(r.unit)} ${esc(r.direction)}</td>
      <td>${esc(r.trigger_label)}</td>
      <td>${esc(r.note)}</td>
    </tr>`).join("");
  return `
    <div class="split">
      <div class="pane">
        <div class="toolbar"><strong>Florida Family Law Rules of Procedure — deadlines</strong></div>
        <div class="stack" id="rules-form">
          <label>Rule
            <select name="rule_id">${opts}</select>
          </label>
          <label>Trigger date
            <input type="date" name="trigger" value="${localDay(new Date())}">
          </label>
          <label>Custom days (optional)
            <input type="number" name="days" min="1" placeholder="uses the rule default">
          </label>
          <label><input type="checkbox" name="service_mail_or_email"> Served by mail or e-mail (add 5 days under Rule 2.514(b), not for statutory periods)</label>
          ${matterSelect("matter_id", "", "Docket to matter (optional)")}
          <button id="btn-compute" class="primary" type="button">Compute</button>
          <div id="compute-out"></div>
        </div>
      </div>
      <div class="side" style="overflow:auto">
        <table>
          <thead><tr><th>Event</th><th>Cite</th><th>Period</th><th>Trigger</th><th>Note</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    </div>`;
}

function renderSettings() {
  const pane = state.settingsPane || "general";
  const tabs = [
    ["general", "General"],
    ["accounts", "Accounts"],
    ["composing", "Composing"],
    ["signatures", "Signatures"],
    ["viewing", "Viewing"],
    ["practice", "Practice"],
  ];
  const tabBtns = tabs.map(([id, label]) =>
    `<button type="button" data-pane="${id}" class="${pane === id ? "active" : ""}">${label}</button>`
  ).join("");
  return `
    <div class="prefs">
      <nav class="prefs-tabs">${tabBtns}</nav>
      <div class="prefs-body">${settingsPaneHtml(pane)}</div>
    </div>`;
}

function settingsPaneHtml(pane) {
  if (pane === "accounts") return settingsAccounts();
  if (pane === "composing") return settingsComposing();
  if (pane === "signatures") return settingsSignatures();
  if (pane === "viewing") return settingsViewing();
  if (pane === "practice") return settingsPractice();
  return settingsGeneral();
}

function settingsGeneral() {
  const interval = settingVal("check_interval", "120");
  const opts = [
    ["120", "Automatically"],
    ["60", "Every minute"],
    ["300", "Every 5 minutes"],
    ["900", "Every 15 minutes"],
    ["1800", "Every 30 minutes"],
    ["3600", "Every hour"],
    ["0", "Manually"],
  ].map(([v, l]) => `<option value="${v}" ${interval === v ? "selected" : ""}>${l}</option>`).join("");
  return `
    <form class="prefs-form" id="settings-form">
      <h2>General</h2>
      <label class="prefs-row">Check for new messages
        <select name="check_interval">${opts}</select>
      </label>
      <label class="check"><input type="checkbox" name="notify_new_mail" ${settingOn("notify_new_mail", "1") ? "checked" : ""}> New message notifications</label>
      <p class="meta">Get Mail always checks immediately. Automatically uses a two-minute interval (Praecipe is IMAP, not push).</p>
      <div class="prefs-actions">
        <button class="primary" type="submit">Save</button>
        <span id="flash"></span>
      </div>
    </form>`;
}

function settingsAccounts() {
  const s = state.settings;
  const accounts = state.accounts || [];
  const rows = accounts.map((a) => `
    <div class="acct-card ${a.is_default ? "default" : ""}">
      <div>
        <strong>${esc(a.display_name || a.email)}</strong>
        <div class="meta">${esc(providerLabel(a.provider))} · ${esc(a.email)} · ${a.auth_type === "oauth" ? "Signed in" : "App password"}</div>
      </div>
      <div class="acct-actions">
        ${a.is_default ? "<span class='badge'>Default</span>" : `<button type="button" data-acct-default="${a.id}">Default</button>`}
        <button type="button" data-acct-test="${a.id}">Test</button>
        <button type="button" data-acct-del="${a.id}">Remove</button>
      </div>
    </div>`).join("") || `<p class="meta">No mailboxes yet. Add Google, Microsoft, or iCloud below — Praecipe cannot use your regular account password.</p>`;
  return `
    <div class="prefs-form">
      <h2>Accounts</h2>
      <div class="acct-add">
        <button type="button" class="primary" data-add-acct="gmail">Add Google</button>
        <button type="button" data-add-acct="microsoft">Add Microsoft 365</button>
        <button type="button" data-add-acct="icloud">Add iCloud</button>
      </div>
      <div class="acct-list">${rows}</div>
      <form id="settings-form">
        <label class="prefs-row">Your name on outgoing mail <input name="display_name" value="${esc(s.display_name || "")}"></label>
        <div class="prefs-actions">
          <button class="primary" type="submit">Save</button>
          <span id="flash"></span>
        </div>
        <details class="acct-advanced">
          <summary>Google browser sign-in</summary>
          <p class="meta">Optional. Microsoft 365 work sign-in is set up when you click Add Microsoft 365.</p>
          <label class="prefs-row">Google client ID <input name="google_oauth_client_id" value="${esc(s.google_oauth_client_id || "")}" placeholder="….apps.googleusercontent.com"></label>
          <label class="prefs-row">Google client secret <input name="google_oauth_client_secret" type="password" placeholder="${s.google_oauth_client_secret_set ? "unchanged" : "from Desktop client"}"></label>
          <p class="meta">Redirect: <code>http://127.0.0.1:12090/oauth/google</code></p>
        </details>
      </form>
    </div>`;
}

function providerLabel(id) {
  const p = (state.providers || []).find((x) => x.id === id);
  return (p && p.label) || id || "IMAP";
}

function providerSpec(id) {
  return (state.providers || []).find((x) => x.id === id) || {};
}

function addAccountModal(provider) {
  if (provider === "microsoft") {
    addMicrosoftModal();
    return;
  }
  const p = providerSpec(provider);
  const oauthReady = p.oauth_ready;
  const getLabel = provider === "gmail" ? "Open Google to get a password" : "Open Apple to get a password";
  const steps = provider === "gmail" ? `
      <ol class="acct-steps">
        <li>Turn on 2-Step Verification if Google asks.</li>
        <li>Enable IMAP in Gmail settings → Forwarding and POP/IMAP.</li>
        <li>Create an app password named Praecipe (16 characters).</li>
        <li>Paste it below — not your Gmail password.</li>
      </ol>` : `
      <ol class="acct-steps">
        <li>Sign-In and Security → App-Specific Passwords → Generate, label Praecipe.</li>
        <li>Paste that password. Your Apple ID password will be rejected.</li>
      </ol>`;
  if (p.app_password_url) window.open(p.app_password_url, "_blank", "noopener");
  openModal(`
    <form class="stack" id="add-account-form">
      <h2 style="margin:0;font-size:15px">${esc(p.label || provider)}</h2>
      <p class="meta">${esc(p.imap_host || "")} · ${esc(p.smtp_host || "")}</p>
      <button type="button" class="primary" id="btn-open-provider" data-url="${esc(p.app_password_url || "")}">${getLabel}</button>
      ${steps}
      <label>Full name <input name="display_name" value="${esc(state.settings.display_name || "")}"></label>
      <label>Email address <input name="email" type="email" required placeholder="${provider === "icloud" ? "name@icloud.com" : ""}"></label>
      <label>App password <input name="password" type="password" autocomplete="off" placeholder="paste from the provider"></label>
      <input type="hidden" name="provider" value="${esc(provider)}">
      <p id="acct-flash" class="meta"></p>
      <div>
        ${oauthReady ? `<button type="button" id="btn-oauth">Sign in with ${esc(p.label)}</button>` : ""}
        <button class="primary" type="submit">Test and add</button>
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`, true);
}

function addMicrosoftModal() {
  const p = providerSpec("microsoft");
  const ready = Boolean(p.oauth_ready);
  openModal(`
    <form class="stack" id="add-account-form">
      <h2 style="margin:0;font-size:15px">Microsoft 365</h2>
      <p class="meta">Work or school mailbox only — not Outlook.com, Hotmail, or a personal Microsoft account. Praecipe never uses your Microsoft password.</p>
      ${ready ? "" : `
        <div class="ms-setup">
          <p><strong>One time, in the firm’s Microsoft 365 admin.</strong> Sign in to Entra as an admin of that tenant, not a personal Microsoft account.</p>
          <ol class="acct-steps">
            <li>Click Register Praecipe, then New registration. Name it <strong>Praecipe</strong>.</li>
            <li>Supported account types: <strong>Accounts in this organizational directory only</strong>. Do not pick personal Microsoft accounts.</li>
            <li>Authentication → Advanced → Allow public client flows: <strong>Yes</strong>. No secret. No redirect URI.</li>
            <li>Copy the Application (client) ID and paste it below.</li>
          </ol>
          <button type="button" id="btn-open-azure" data-url="${esc(p.azure_url || "https://aka.ms/AppRegistrations")}">Register Praecipe in Microsoft 365</button>
          <label>Application (client) ID <input name="microsoft_oauth_client_id" required placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" autocomplete="off"></label>
        </div>`}
      <label>Your name <input name="display_name" value="${esc(state.settings.display_name || "")}"></label>
      <label>Work email <input name="email" type="email" required placeholder="you@yourfirm.com"></label>
      <input type="hidden" name="provider" value="microsoft">
      <div id="ms-device" class="ms-device hidden">
        <p class="meta">Microsoft opened a work sign-in page. Enter this code:</p>
        <p class="ms-code" id="ms-user-code"></p>
        <p class="meta">If nothing opened, go to <a id="ms-device-link" href="https://microsoft.com/devicelogin" target="_blank" rel="noopener">microsoft.com/devicelogin</a> and use your work account.</p>
      </div>
      <p id="acct-flash" class="meta"></p>
      <div>
        <button type="button" class="primary" id="btn-ms-signin">Sign in with Microsoft 365</button>
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`, true);
}

async function startMicrosoftSignIn() {
  const form = $("#add-account-form");
  const flash = $("#acct-flash");
  const btn = $("#btn-ms-signin");
  if (!form) return;
  const p = formObj(form);
  try {
    if (flash) {
      flash.textContent = "";
      flash.className = "meta";
    }
    if (p.microsoft_oauth_client_id) {
      await api("/api/settings", { method: "POST", body: { microsoft_oauth_client_id: String(p.microsoft_oauth_client_id).trim() } });
      state.settings = await api("/api/settings");
      state.providers = await api("/api/accounts/providers");
    }
    if (btn) btn.disabled = true;
    const out = await api("/api/oauth/microsoft/device", {
      method: "POST",
      body: { email: p.email || "", display_name: p.display_name || "" },
    });
    const box = $("#ms-device");
    const codeEl = $("#ms-user-code");
    const link = $("#ms-device-link");
    if (codeEl) codeEl.textContent = out.user_code || "";
    if (link) {
      link.href = out.verification_uri || "https://microsoft.com/devicelogin";
      link.textContent = (out.verification_uri || "https://microsoft.com/devicelogin").replace(/^https?:\/\//, "");
    }
    if (box) box.classList.remove("hidden");
    const openUrl = out.verification_uri_complete || out.verification_uri;
    if (openUrl) window.open(openUrl, "praecipe-ms-login", "noopener");
    if (flash) flash.textContent = "Finish sign-in in the Microsoft window. This page updates when it succeeds.";
    await waitForOauth(out.state);
    closeModal();
    await refreshCore();
    state.view = "settings";
    state.settingsPane = "accounts";
    setStatus("Microsoft 365 account added.");
    render();
  } catch (err) {
    if (btn) btn.disabled = false;
    if (flash) {
      flash.textContent = err.message;
      flash.className = "error";
    }
  }
}

function signatureOptions(selected) {
  const cur = selected == null ? settingVal("compose_signature", "default") : String(selected);
  const items = (state.signatures || []).map((s) =>
    `<option value="${s.id}" ${cur === String(s.id) || (cur === "default" && s.is_default) ? "selected" : ""}>${esc(s.name)}</option>`
  ).join("");
  return `
    <option value="none" ${cur === "none" ? "selected" : ""}>None</option>
    ${items}
    <option value="random" ${cur === "random" ? "selected" : ""}>At Random</option>`;
}

function settingsComposing() {
  return `
    <form class="prefs-form" id="settings-form">
      <h2>Composing</h2>
      <p class="prefs-label">Message format</p>
      <p class="meta">Plain Text</p>
      <label class="check"><input type="checkbox" name="quote_original" ${settingOn("quote_original", "1") ? "checked" : ""}> Quote the text of the original message</label>
      <label class="check"><input type="checkbox" name="bcc_self" ${settingOn("bcc_self", "0") ? "checked" : ""}> Automatically Bcc myself</label>
      <label class="prefs-row">Choose signature
        <select name="compose_signature">${signatureOptions()}</select>
      </label>
      <div class="prefs-actions">
        <button class="primary" type="submit">Save</button>
        <span id="flash"></span>
      </div>
    </form>`;
}

function settingsSignatures() {
  const list = state.signatures || [];
  const selected = list.find((s) => s.id === state.signatureId) || list[0] || null;
  const rows = list.map((s) =>
    `<button type="button" class="sig-item ${selected && selected.id === s.id ? "active" : ""}" data-sig-id="${s.id}">${esc(s.name)}${s.is_default ? " ★" : ""}</button>`
  ).join("");
  const editor = selected ? `
    <label class="prefs-row">Signature Name <input name="sig_name" value="${esc(selected.name || "")}"></label>
    <textarea name="sig_body" class="sig-body" placeholder="Your name, firm, and confidentiality notice">${esc(selected.body || "")}</textarea>
    <button type="button" id="btn-sig-default">Use this signature by default</button>
  ` : `<p class="meta">Create a signature with the + button.</p>`;
  return `
    <div class="sig-pane">
      <div class="sig-col">
        <div class="sig-list">${rows || `<div class="empty" style="padding:16px">No signatures</div>`}</div>
        <div class="sig-tools">
          <button type="button" id="btn-sig-add" title="Add">+</button>
          <button type="button" id="btn-sig-del" title="Remove" ${selected ? "" : "disabled"}>−</button>
        </div>
      </div>
      <div class="sig-editor">
        ${editor}
        <form class="prefs-form" id="settings-form">
          <label class="check"><input type="checkbox" name="sig_above_quote" ${settingOn("sig_above_quote", "1") ? "checked" : ""}> Place signature above quoted text</label>
          <label class="prefs-row">Choose Signature
            <select name="compose_signature">${signatureOptions()}</select>
          </label>
          <div class="prefs-actions">
            <button class="primary" type="submit">Save</button>
            <span id="flash"></span>
          </div>
        </form>
      </div>
    </div>`;
}

function settingsViewing() {
  return `
    <form class="prefs-form" id="settings-form">
      <h2>Viewing</h2>
      <label class="check"><input type="checkbox" name="show_preview" ${settingOn("show_preview", "1") ? "checked" : ""}> Show preview in message list</label>
      <label class="check"><input type="checkbox" name="mark_read_on_open" ${settingOn("mark_read_on_open", "1") ? "checked" : ""}> Mark messages as read when opened</label>
      <label class="check"><input type="checkbox" name="load_remote_images" ${settingOn("load_remote_images", "0") ? "checked" : ""}> Load remote images in messages</label>
      <p class="meta">Remote images are blocked unless you turn this on — same idea as Mail’s privacy setting.</p>
      <div class="prefs-actions">
        <button class="primary" type="submit">Save</button>
        <span id="flash"></span>
      </div>
    </form>`;
}

function settingsPractice() {
  const s = state.settings;
  return `
    <form class="prefs-form" id="settings-form">
      <h2>Practice</h2>
      <label class="prefs-row">Default billing rate <input name="default_rate" type="number" step="0.01" value="${esc(s.default_rate || "")}"></label>
      <label class="prefs-row">County / division <input name="county" value="${esc(s.county || "")}" placeholder="Lee County · Family"></label>
      <label class="check"><input type="checkbox" name="auto_docket" ${settingOn("auto_docket", "1") ? "checked" : ""}> Automatically docket dates and Fla. Fam. L. R. P. deadlines found in opened mail</label>
      <label class="check"><input type="checkbox" name="auto_download_service" ${settingOn("auto_download_service", "0") ? "checked" : ""}> Automatically download likely service-document URLs when a message is opened</label>
      <div class="prefs-actions">
        <button class="primary" type="submit">Save</button>
        <span id="flash"></span>
      </div>
    </form>`;
}

const SIG_MARK = "\n\n-- \n";

function defaultComposeSigId() {
  const chosen = settingVal("compose_signature", "default");
  if (chosen === "none" || chosen === "random") return chosen;
  if (chosen && chosen !== "default") return chosen;
  const def = (state.signatures || []).find((s) => s.is_default);
  return def ? String(def.id) : "none";
}

function signatureBodyFor(id) {
  if (!id || id === "none") return "";
  const list = state.signatures || [];
  if (id === "random") {
    if (!list.length) return "";
    return list[Math.floor(Math.random() * list.length)].body || "";
  }
  const row = list.find((s) => String(s.id) === String(id));
  return (row && row.body) || "";
}

function quotedBlockFrom(prefill) {
  const raw = prefill.quoted != null ? prefill.quoted : (prefill.body || "");
  const match = String(raw).match(/(\n\n(?:On .+ wrote:|---------- Forwarded message ----------)[\s\S]*)$/);
  return match ? match[1] : (prefill.quoted || "");
}

function assembleComposeBody(user, sigBody, quoted) {
  const above = settingOn("sig_above_quote", "1");
  const sig = sigBody ? SIG_MARK + sigBody : "";
  const q = quoted || "";
  if (q && above) return (user || "") + sig + q;
  if (q) return (user || "") + q + sig;
  return (user || "") + sig;
}

function stripComposeParts(full, quoted) {
  let text = full || "";
  if (quoted && text.endsWith(quoted)) text = text.slice(0, -quoted.length);
  const idx = text.lastIndexOf(SIG_MARK);
  if (idx >= 0) text = text.slice(0, idx);
  return text;
}

function openModal(html, wide) {
  $("#modal-card").className = "modal-card" + (wide ? " wide" : "");
  $("#modal-card").innerHTML = html;
  $("#modal").classList.remove("hidden");
}
function closeModal() {
  $("#modal").classList.add("hidden");
  $("#modal-card").innerHTML = "";
}

function composeForm(prefill = {}) {
  state.compose = prefill;
  const sigId = prefill.signature_id || defaultComposeSigId();
  const quoted = settingOn("quote_original", "1") ? quotedBlockFrom(prefill) : "";
  const user = prefill.userBody || "";
  const body = assembleComposeBody(user, signatureBodyFor(sigId), quoted);
  const accounts = state.accounts || [];
  const selectedAcct = prefill.account_id || (accounts.find((a) => a.is_default) || accounts[0] || {}).id || "";
  const fromOpts = accounts.map((a) =>
    `<option value="${a.id}" ${String(selectedAcct) === String(a.id) ? "selected" : ""}>${esc(a.display_name || a.email)} — ${esc(a.email)}</option>`
  ).join("");
  openModal(`
    <form class="stack" id="compose-form">
      <h2 style="font-family:var(--sans);font-size:15px;font-weight:650;margin:0">${esc(prefill.heading || "New Message")}</h2>
      <label>To <input name="to" required value="${esc(prefill.to || "")}" list="people-list"></label>
      <label>Cc <input name="cc" value="${esc(prefill.cc || "")}" list="people-list"></label>
      <label>Bcc <input name="bcc" value="${esc(prefill.bcc || "")}" list="people-list"></label>
      <label>Subject <input name="subject" value="${esc(prefill.subject || "")}"></label>
      <div class="compose-meta">
        <label>From <select name="account_id">${fromOpts || `<option value="">Add an account in Settings</option>`}</select></label>
        <label>Signature
          <select name="signature_id" id="compose-sig">${signatureOptions(sigId)}</select>
        </label>
      </div>
      <label>Matter ${matterSelect("matter_id", prefill.matter_id || state.message?.matter_id || "")}</label>
      <label>Body <textarea name="body" class="compose-body">${esc(body)}</textarea></label>
      <label>Attachments <input name="files" type="file" multiple></label>
      <input type="hidden" name="quoted" value="${esc(quoted)}">
      <input type="hidden" name="in_reply_to" value="${esc(prefill.in_reply_to || "")}">
      <input type="hidden" name="references" value="${esc(prefill.references || "")}">
      <input type="hidden" name="answered_id" value="${esc(prefill.answered_id || "")}">
      <datalist id="people-list">${state.contacts.map((c) => `<option value="${esc(c.email)}">${esc(c.name)}</option>`).join("")}</datalist>
      <div>
        <button class="primary" type="submit">Send</button>
        <button type="button" id="btn-draft">Save as Draft</button>
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`, true);
  $("#compose-sig")?.addEventListener("change", () => {
    const ta = $("textarea[name=body]", $("#compose-form"));
    const q = $("input[name=quoted]", $("#compose-form"))?.value || "";
    const userText = stripComposeParts(ta.value, q);
    ta.value = assembleComposeBody(userText, signatureBodyFor($("#compose-sig").value), q);
  });
}

function matterForm(existing) {
  const m = existing || {};
  openModal(`
    <form class="form-grid" id="matter-form">
      <h2 class="span-2" style="font-family:var(--serif);margin:0">${m.id ? "Edit matter" : "New matter"}</h2>
      <label>Case number <input name="case_no" value="${esc(m.case_no || "")}"></label>
      <label>County <input name="county" value="${esc(m.county || "")}"></label>
      <label>Petitioner <input name="petitioner" value="${esc(m.petitioner || "")}"></label>
      <label>Respondent <input name="respondent" value="${esc(m.respondent || "")}"></label>
      <label class="span-2">Style / caption <input name="style" value="${esc(m.style || "")}" placeholder="filled from parties if blank"></label>
      <label>Opposing counsel <input name="opposing_counsel" value="${esc(m.opposing_counsel || "")}"></label>
      <label>Rate <input name="rate" type="number" step="0.01" value="${esc(m.rate || "")}"></label>
      <label>Client name <input name="client_name" value="${esc(m.client_name || "")}"></label>
      <label>Client email <input name="client_email" type="email" value="${esc(m.client_email || "")}"></label>
      <label>Status
        <select name="status">
          ${["open","pending","closed"].map((s) => `<option ${m.status === s ? "selected" : ""}>${s}</option>`).join("")}
        </select>
      </label>
      <label class="span-2">Notes <textarea name="notes">${esc(m.notes || "")}</textarea></label>
      <input type="hidden" name="id" value="${m.id || ""}">
      <div class="span-2">
        <button class="primary" type="submit">Save</button>
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`);
}

function eventForm(prefill = {}) {
  const start = prefill.start_at || `${localDay(new Date())}T09:00`;
  const allDay = prefill.all_day === 1 || prefill.all_day === true;
  openModal(`
    <form class="stack" id="event-form">
      <h2 style="font-family:var(--serif);margin:0">Calendar</h2>
      <label>Title <input name="title" required value="${esc(prefill.title || "")}"></label>
      <label>Type
        <select name="event_type">
          ${["hearing","deposition","mediation","deadline","appointment","service"].map((t) =>
            `<option ${prefill.event_type === t ? "selected" : ""}>${t}</option>`).join("")}
        </select>
      </label>
      <label>Start <input type="datetime-local" name="start_at" required value="${esc(String(start).slice(0, 16))}"></label>
      <label>End <input type="datetime-local" name="end_at" value="${esc(String(prefill.end_at || "").slice(0, 16))}"></label>
      <label><input type="checkbox" name="all_day" ${allDay ? "checked" : ""}> All day</label>
      <label>Remind (minutes before) <input type="number" name="remind_minutes" value="${esc(prefill.remind_minutes ?? 30)}"></label>
      <label>Location <input name="location" value="${esc(prefill.location || "")}"></label>
      <label>Matter ${matterSelect("matter_id", prefill.matter_id || state.message?.matter_id || "")}</label>
      <label>Notes <textarea name="notes">${esc(prefill.notes || "")}</textarea></label>
      <div>
        <button class="primary" type="submit">Save</button>
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`);
}

function noteForm(prefill = {}) {
  openModal(`
    <form class="stack" id="note-form">
      <h2 style="font-family:var(--serif);margin:0">Note</h2>
      <label>Title <input name="title" value="${esc(prefill.title || "")}"></label>
      <label>Matter ${matterSelect("matter_id", prefill.matter_id || state.message?.matter_id || "")}</label>
      <label>Body <textarea name="body" required>${esc(prefill.body || "")}</textarea></label>
      <input type="hidden" name="id" value="${prefill.id || ""}">
      <div>
        <button class="primary" type="submit">Save</button>
        ${prefill.id ? `<button type="button" id="btn-del-note">Delete</button>` : ""}
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`);
}

function contactForm(prefill = {}) {
  openModal(`
    <form class="stack" id="contact-form">
      <h2 style="font-family:var(--serif);margin:0">${prefill.id ? "Edit contact" : "New contact"}</h2>
      <label>Name <input name="name" value="${esc(prefill.name || "")}"></label>
      <label>Email <input name="email" type="email" required value="${esc(prefill.email || "")}"></label>
      <label>Phone <input name="phone" value="${esc(prefill.phone || "")}"></label>
      <label>Firm <input name="firm" value="${esc(prefill.firm || "")}"></label>
      <label>Matter ${matterSelect("matter_id", prefill.matter_id || "")}</label>
      <label>Notes <textarea name="notes">${esc(prefill.notes || "")}</textarea></label>
      <input type="hidden" name="id" value="${prefill.id || ""}">
      <div>
        <button class="primary" type="submit">Save</button>
        ${prefill.id ? `<button type="button" id="btn-del-contact">Delete</button>` : ""}
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`);
}

function timeForm() {
  openModal(`
    <form class="stack" id="time-form">
      <h2 style="font-family:var(--serif);margin:0">Time entry</h2>
      <label>Matter ${matterSelect("matter_id", state.message?.matter_id || "")}</label>
      <label>Minutes <input name="minutes" type="number" step="0.1" required></label>
      <label>Activity <input name="activity" value="legal services"></label>
      <label>Description <textarea name="description"></textarea></label>
      <label>Rate <input name="rate" type="number" step="0.01" value="${esc(state.settings.default_rate || "")}"></label>
      <div>
        <button class="primary" type="submit">Save</button>
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`);
}

function formObj(form) {
  const data = {};
  for (const el of form.elements) {
    if (!el.name || el.type === "file") continue;
    if (el.type === "checkbox") data[el.name] = el.checked;
    else if (el.type === "number") data[el.name] = el.value === "" ? null : Number(el.value);
    else data[el.name] = el.value;
  }
  return data;
}

async function loadMail() {
  const q = encodeURIComponent(state.query || "");
  const folder = encodeURIComponent(state.filter ? "ALL" : (state.folder || "INBOX"));
  const filter = state.filter ? `&filter=${encodeURIComponent(state.filter)}` : "";
  state.mail = await api(`/api/mail?folder=${folder}&q=${q}${filter}`);
  state.folders = await api("/api/mail/folders");
  state.smart = await api("/api/mail/smart");
  renderUnread();
}

async function openMail(id) {
  state.selectedMail = id;
  state.message = await api(`/api/mail/${id}`);
  try {
    state.extract = await api(`/api/mail/${id}/extract`);
  } catch {
    state.extract = { events: [], urls: [], deadlines: [] };
  }
  if (!state.message.seen && settingOn("mark_read_on_open", "1")) {
    try { await api(`/api/mail/${id}/read`, { method: "POST", body: {} }); state.message.seen = 1; } catch {}
  }
  try {
    const applied = await api(`/api/mail/${id}/apply-practice`, { method: "POST", body: {} });
    if (applied.extract) state.extract = applied.extract;
    if ((applied.added_events || []).length) {
      await refreshCore();
      setStatus(`Docketed ${applied.added_events.length} date(s) from this message.`);
    }
  } catch {}
  render();
}

async function toggleTimer() {
  if (state.timer) {
    await api("/api/time/stop", { method: "POST", body: {} });
  } else {
    await api("/api/time/start", {
      method: "POST",
      body: {
        matter_id: state.message?.matter_id || null,
        message_id: state.message?.id || null,
        description: state.message ? `Email: ${state.message.subject}` : "Timer",
        activity: "email",
      },
    });
  }
  await refreshCore();
  render();
}

async function quote(mode) {
  if (!state.message) return;
  const q = await api(`/api/mail/${state.message.id}/quote?mode=${mode}`);
  const atts = mode === "forward" ? (state.message.attachments || []) : [];
  const forwarded = [];
  for (const a of atts) {
    forwarded.push({ filename: a.filename, mime: a.mime, href: `/api/attachments/${a.id}` });
  }
  composeForm({
    heading: mode === "forward" ? "Forward" : mode === "reply-all" ? "Reply All" : "Reply",
    ...q,
    answered_id: mode === "forward" ? "" : state.message.id,
  });
}

async function submitCompose(form, draft) {
  const p = formObj(form);
  p.draft = draft;
  p.include_signature = false;
  delete p.quoted;
  delete p.signature_id;
  p.attachments = await filesToPayload(form.elements.files?.files);
  const out = await api("/api/mail/send", { method: "POST", body: p });
  if (!out.ok) throw new Error(out.error || "Send failed");
  closeModal();
  await loadMail();
  render();
}

function bindView() {
  $$("[data-folder]").forEach((el) => {
    el.addEventListener("click", async () => {
      state.folder = el.dataset.folder;
      state.selectedMail = null;
      state.message = null;
      await loadMail();
      render();
    });
  });
  $$(".list-item[data-id]").forEach((el) => {
    el.addEventListener("click", () => openMail(Number(el.dataset.id)));
  });
  const assign = $("select[name='assign']");
  if (assign) {
    assign.addEventListener("change", async () => {
      const matter_id = assign.value ? Number(assign.value) : null;
      await api(`/api/mail/${state.message.id}/assign`, { method: "POST", body: { matter_id } });
      await openMail(state.message.id);
    });
  }
  $("#btn-reply")?.addEventListener("click", () => quote("reply"));
  $("#btn-reply-all")?.addEventListener("click", () => quote("reply-all"));
  $("#btn-forward")?.addEventListener("click", () => quote("forward"));
  $("#btn-delete")?.addEventListener("click", async () => {
    if (!state.message) return;
    await api(`/api/mail/${state.message.id}/delete`, { method: "POST", body: {} });
    state.message = null;
    state.selectedMail = null;
    await loadMail();
    render();
  });
  $("#btn-unread")?.addEventListener("click", async () => {
    await api(`/api/mail/${state.message.id}/unread`, { method: "POST", body: {} });
    await loadMail();
    render();
  });
  $("#btn-flag")?.addEventListener("click", async () => {
    await api(`/api/mail/${state.message.id}/flag`, { method: "POST", body: { add: !state.message.flagged } });
    await openMail(state.message.id);
  });
  $("#btn-timer")?.addEventListener("click", toggleTimer);
  $("#fb-matter")?.addEventListener("change", () => {
    const opt = $("#fb-matter").selectedOptions[0];
    if (opt?.dataset.client) $("#fb-client").value = opt.dataset.client;
    const match = (state.message?.matches || []).find((m) => String(m.matter_id) === opt.value);
    const el = $("#fb-conf");
    if (el && match) {
      el.className = `conf ${confClass(match.confidence)}`;
      el.textContent = `${match.confidence}% — ${(match.reasons || []).join("; ") || "selected"}`;
    }
  });
  $("#filebill")?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    const p = formObj(ev.target);
    const status = $("#filebill-status");
    status.textContent = "Working…";
    try {
      const out = await api(`/api/mail/${state.message.id}/file-and-bill`, { method: "POST", body: p });
      const bits = [];
      if (out.connected) bits.push("connected");
      if ((out.saved || []).length) bits.push(`${out.saved.length} file(s) in ${out.doc_type}`);
      if ((out.downloaded || []).length) bits.push(`${out.downloaded.length} URL(s)`);
      if (out.email?.ok) bits.push("emailed client");
      if (out.email && !out.email.ok) bits.push(out.email.error);
      if (out.time) bits.push(`${out.time.minutes} min`);
      status.textContent = bits.join(" · ") || "Done.";
      status.className = out.email && !out.email.ok ? "error" : "ok";
      await refreshCore();
      await loadMail();
      await openMail(state.message.id);
    } catch (err) {
      status.textContent = err.message;
      status.className = "error";
    }
  });
  $("#btn-note-mail")?.addEventListener("click", () => {
    noteForm({
      title: state.message?.subject,
      matter_id: state.message?.matter_id,
      body: `Re: ${state.message?.subject}\nFrom: ${state.message?.from_addr}\n\n`,
    });
  });
  $$("[data-add-event]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const e = state.extract.events[Number(btn.dataset.addEvent)];
      await api("/api/events", {
        method: "POST",
        body: {
          title: e.title,
          event_type: e.event_type,
          start_at: e.date,
          all_day: true,
          matter_id: state.message?.matter_id,
          message_id: state.message?.id,
          source: "email",
          notes: e.context,
        },
      });
      await refreshCore();
      setStatus("Added to the calendar.");
      render();
    });
  });
  $$("[data-dl]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const u = state.extract.urls[Number(btn.dataset.dl)];
      try {
        const out = await api("/api/files/download-url", {
          method: "POST",
          body: { url: u.url, matter_id: state.message?.matter_id, message_id: state.message?.id },
        });
        setStatus(`Downloaded ${out.filename}`);
        state.files = await api("/api/files");
        render();
      } catch (err) {
        setStatus(err.message, true);
        render();
      }
    });
  });
  $$("[data-add-deadline]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const d = state.extract.deadlines[Number(btn.dataset.addDeadline)];
      if (!d.trigger) return setStatus("No trigger date on this message.", true);
      await api("/api/deadlines/compute", {
        method: "POST",
        body: {
          rule_id: d.rule_id,
          trigger: d.trigger,
          save: true,
          matter_id: state.message?.matter_id,
          message_id: state.message?.id,
          service_mail_or_email: true,
        },
      });
      await refreshCore();
      setStatus("Deadline docketed.");
      render();
    });
  });
  $("#btn-new-matter")?.addEventListener("click", () => matterForm());
  $$("[data-edit-matter]").forEach((row) => {
    row.addEventListener("click", () => {
      const m = state.matters.find((x) => x.id === Number(row.dataset.editMatter));
      matterForm(m);
    });
  });
  $("#prev-month")?.addEventListener("click", () => {
    state.month = new Date(state.month.getFullYear(), state.month.getMonth() - 1, 1);
    render();
  });
  $("#next-month")?.addEventListener("click", () => {
    state.month = new Date(state.month.getFullYear(), state.month.getMonth() + 1, 1);
    render();
  });
  $("#cal-month")?.addEventListener("click", () => { state.calMode = "month"; render(); });
  $("#cal-week")?.addEventListener("click", () => { state.calMode = "week"; render(); });
  $("#btn-new-event")?.addEventListener("click", () => eventForm());
  $$("[data-day]").forEach((el) => {
    el.addEventListener("click", (ev) => {
      if (ev.target.closest("button")) return;
      eventForm({ start_at: `${el.dataset.day}T09:00` });
    });
  });
  $$("[data-del-event]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      await api(`/api/events/${btn.dataset.delEvent}`, { method: "DELETE" });
      await refreshCore();
      render();
    });
  });
  $("#btn-add-time")?.addEventListener("click", timeForm);
  $$("[data-billed]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      await api(`/api/time/${btn.dataset.billed}/billed`, { method: "POST", body: { billed: Number(btn.dataset.on) } });
      await refreshCore();
      render();
    });
  });
  $("#btn-new-note")?.addEventListener("click", () => noteForm());
  $$("[data-edit-note]").forEach((el) => {
    el.addEventListener("click", () => {
      const n = state.notes.find((x) => x.id === Number(el.dataset.editNote));
      noteForm(n);
    });
  });
  $("#btn-new-contact")?.addEventListener("click", () => contactForm());
  $$("[data-edit-contact]").forEach((el) => {
    el.addEventListener("click", () => {
      const c = state.contacts.find((x) => x.id === Number(el.dataset.editContact));
      contactForm(c);
    });
  });
  $("#btn-upload")?.addEventListener("click", async () => {
    const matter = $("select[name=upload_matter]")?.value;
    const input = $("#upload-files");
    if (!input?.files?.length) return;
    const files = await filesToPayload(input.files);
    await api("/api/files/upload", { method: "POST", body: { matter_id: matter ? Number(matter) : null, files } });
    state.files = await api("/api/files");
    render();
  });
  const htmlFrame = $(".mail-html");
  if (htmlFrame && state.message?.body_html) {
    const csp = settingOn("load_remote_images", "0")
      ? ""
      : `<meta http-equiv="Content-Security-Policy" content="img-src 'none'; media-src 'none';">`;
    htmlFrame.srcdoc = csp + state.message.body_html;
  }
  $("#btn-compute")?.addEventListener("click", async () => {
    const wrap = $("#rules-form");
    const data = {
      rule_id: $("[name=rule_id]", wrap).value,
      trigger: $("[name=trigger]", wrap).value,
      days: $("[name=days]", wrap).value ? Number($("[name=days]", wrap).value) : null,
      service_mail_or_email: $("[name=service_mail_or_email]", wrap).checked,
      matter_id: $("[name=matter_id]", wrap).value ? Number($("[name=matter_id]", wrap).value) : null,
      save: Boolean($("[name=matter_id]", wrap).value),
    };
    try {
      const out = await api("/api/deadlines/compute", { method: "POST", body: data });
      if (data.save) await refreshCore();
      $("#compute-out").innerHTML = `<p class="ok"><strong>Due ${esc(out.due)} (${esc(out.weekday)})</strong><br>${esc(out.rule)}<br>${out.service_extra_applied ? "Includes +5 days for mail/e-mail service. " : ""}${esc(out.note)}</p>`;
    } catch (err) {
      $("#compute-out").innerHTML = `<p class="error">${esc(err.message)}</p>`;
    }
  });
  $("#settings-form")?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    await persistSignatureEditor();
    await persistSettings(ev.target, false);
    setStatus("Settings saved.");
    const flash = $("#flash");
    if (flash) flash.textContent = "Saved.";
    startMailPoll();
  });
  $("#settings-form")?.addEventListener("change", async (ev) => {
    if (!ev.target.matches("input[type=checkbox], select")) return;
    if (ev.target.name === "notify_new_mail" && ev.target.checked && window.Notification && Notification.permission === "default") {
      Notification.requestPermission();
    }
    await persistSettings(ev.currentTarget, true);
    startMailPoll();
  });
  $("#preset")?.addEventListener("change", (ev) => {
    const presets = {
      gmail: { imap_host: "imap.gmail.com", imap_port: "993", smtp_host: "smtp.gmail.com", smtp_port: "465", smtp_tls: "ssl" },
      outlook: { imap_host: "outlook.office365.com", imap_port: "993", smtp_host: "smtp.office365.com", smtp_port: "587", smtp_tls: "starttls" },
      yahoo: { imap_host: "imap.mail.yahoo.com", imap_port: "993", smtp_host: "smtp.mail.yahoo.com", smtp_port: "465", smtp_tls: "ssl" },
      icloud: { imap_host: "imap.mail.me.com", imap_port: "993", smtp_host: "smtp.mail.me.com", smtp_port: "587", smtp_tls: "starttls" },
    };
    const p = presets[ev.target.value];
    if (!p) return;
    const form = $("#settings-form");
    for (const [k, v] of Object.entries(p)) form.elements[k].value = v;
  });
  $$(".prefs-tabs [data-pane]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      if (state.settingsPane === btn.dataset.pane) return;
      const form = $("#settings-form");
      try {
        if (form) await persistSettings(form, true);
        await persistSignatureEditor();
      } catch (err) {
        setStatus(err.message, true);
      }
      state.settingsPane = btn.dataset.pane;
      render();
    });
  });
  $$("[data-sig-id]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      await persistSignatureEditor();
      state.signatureId = Number(btn.dataset.sigId);
      render();
    });
  });
  $("[name=sig_name]")?.addEventListener("blur", persistSignatureEditor);
  $("[name=sig_body]")?.addEventListener("blur", persistSignatureEditor);
  $("#btn-sig-add")?.addEventListener("click", async () => {
    await persistSignatureEditor();
    const row = await api("/api/signatures", { method: "POST", body: { name: "Signature", body: "" } });
    state.signatures = await api("/api/signatures");
    state.signatureId = row.id;
    render();
  });
  $("#btn-sig-del")?.addEventListener("click", async () => {
    if (!state.signatureId) return;
    await api(`/api/signatures/${state.signatureId}`, { method: "DELETE" });
    state.signatures = await api("/api/signatures");
    const def = state.signatures.find((s) => s.is_default) || state.signatures[0];
    state.signatureId = def ? def.id : null;
    render();
  });
  $("#btn-sig-default")?.addEventListener("click", async () => {
    if (!state.signatureId) return;
    await persistSignatureEditor();
    await api(`/api/signatures/${state.signatureId}/default`, { method: "POST", body: {} });
    state.signatures = await api("/api/signatures");
    state.settings = await api("/api/settings");
    render();
  });
  $$("[data-add-acct]").forEach((btn) => {
    btn.addEventListener("click", () => addAccountModal(btn.dataset.addAcct));
  });
  $$("[data-acct-del]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      await api(`/api/accounts/${btn.dataset.acctDel}`, { method: "DELETE" });
      await refreshCore();
      render();
    });
  });
  $$("[data-acct-default]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      await api(`/api/accounts/${btn.dataset.acctDefault}/default`, { method: "POST", body: {} });
      await refreshCore();
      render();
    });
  });
  $$("[data-acct-test]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      try {
        const out = await api(`/api/accounts/${btn.dataset.acctTest}/test`, { method: "POST", body: {} });
        setStatus(out.ok ? `Connected ${out.email}` : (out.error || "Test failed"));
      } catch (err) {
        setStatus(err.message, true);
      }
      render();
    });
  });
}

function bindGlobal() {
  $("#btn-sync").addEventListener("click", async () => {
    setStatus("Send/Receive…");
    render();
    try {
      const out = await api("/api/mail/sync", { method: "POST", body: {} });
      await loadMail();
      setStatus(out.ok ? `Updated. ${out.added} new. ${out.unseen || 0} unread.` : (out.error || "Sync failed"));
      notifyNewMail(out.added);
    } catch (err) {
      setStatus(err.message, true);
    }
    render();
  });
  $("#btn-compose").addEventListener("click", () => composeForm({}));
  $("#search").addEventListener("keydown", async (ev) => {
    if (ev.key !== "Enter") return;
    state.query = ev.target.value;
    state.view = "mail";
    await loadMail();
    render();
  });
  $("#modal").addEventListener("click", (ev) => {
    if (ev.target.id === "modal") closeModal();
  });
  document.addEventListener("click", async (ev) => {
    if (ev.target.id === "cancel-modal") closeModal();
    if (ev.target.id === "btn-draft") {
      ev.preventDefault();
      const form = $("#compose-form");
      if (form) await submitCompose(form, true);
    }
    if (ev.target.id === "btn-open-provider") {
      ev.preventDefault();
      const url = ev.target.dataset.url;
      if (url) window.open(url, "_blank", "noopener");
    }
    if (ev.target.id === "btn-open-azure") {
      ev.preventDefault();
      const url = ev.target.dataset.url;
      if (url) window.open(url, "_blank", "noopener");
    }
    if (ev.target.id === "btn-ms-signin") {
      ev.preventDefault();
      startMicrosoftSignIn();
    }
    if (ev.target.id === "btn-oauth") {
      ev.preventDefault();
      const form = $("#add-account-form");
      const flash = $("#acct-flash");
      try {
        const p = formObj(form);
        const out = await api("/api/oauth/start", { method: "POST", body: p });
        window.open(out.url, "praecipe-oauth", "width=480,height=720");
        if (flash) flash.textContent = "Finish sign-in in the popup, then this window will update.";
        await waitForOauth(out.state);
        closeModal();
        await refreshCore();
        state.view = "settings";
        state.settingsPane = "accounts";
        setStatus("Account added.");
        render();
      } catch (err) {
        if (flash) {
          flash.textContent = err.message;
          flash.className = "error";
        }
      }
    }
    if (ev.target.id === "btn-del-note") {
      const id = $("[name=id]", $("#note-form")).value;
      await api(`/api/notes/${id}`, { method: "DELETE" });
      closeModal();
      state.notes = await api("/api/notes");
      render();
    }
    if (ev.target.id === "btn-del-contact") {
      const id = $("[name=id]", $("#contact-form")).value;
      await api(`/api/contacts/${id}`, { method: "DELETE" });
      closeModal();
      state.contacts = await api("/api/contacts");
      render();
    }
  });
  document.addEventListener("keydown", (ev) => {
    const tag = (ev.target.tagName || "").toLowerCase();
    if (["input", "textarea", "select"].includes(tag) || !$("#modal").classList.contains("hidden")) {
      if (ev.key === "Escape") closeModal();
      return;
    }
    if (ev.key === "/" ) { ev.preventDefault(); $("#search").focus(); }
    if (ev.key === "n" || ev.key === "c") composeForm({});
    if (ev.key === "r") quote("reply");
    if (ev.key === "a") quote("reply-all");
    if (ev.key === "f") quote("forward");
    if (ev.key === "u" && state.message) api(`/api/mail/${state.message.id}/unread`, { method: "POST", body: {} }).then(loadMail).then(render);
    if (ev.key === "Delete" && state.message) $("#btn-delete")?.click();
    if (ev.key === "j" || ev.key === "k") {
      const ids = state.mail.map((m) => m.id);
      const i = ids.indexOf(state.selectedMail);
      const next = ev.key === "j" ? ids[i + 1] : ids[i - 1];
      if (next) openMail(next);
    }
  });
  document.addEventListener("submit", async (ev) => {
    if (ev.target.id === "filebill") return;
    if (ev.target.id === "compose-form") {
      ev.preventDefault();
      try { await submitCompose(ev.target, false); }
      catch (err) { alert(err.message); }
    }
    if (ev.target.id === "add-account-form") {
      ev.preventDefault();
      const p = formObj(ev.target);
      if (p.provider === "microsoft") {
        startMicrosoftSignIn();
        return;
      }
      const flash = $("#acct-flash");
      try {
        if (flash) flash.textContent = "Testing sign-in with the provider…";
        await api("/api/accounts", { method: "POST", body: p });
        closeModal();
        await refreshCore();
        state.view = "settings";
        state.settingsPane = "accounts";
        setStatus("Account added.");
        render();
      } catch (err) {
        if (flash) {
          flash.textContent = err.message;
          flash.className = "error";
        } else alert(err.message);
      }
    }
    if (ev.target.id === "matter-form") {
      ev.preventDefault();
      const p = formObj(ev.target);
      const id = p.id;
      delete p.id;
      if (id) await api(`/api/matters/${id}`, { method: "POST", body: p });
      else await api("/api/matters", { method: "POST", body: p });
      closeModal();
      await refreshCore();
      render();
    }
    if (ev.target.id === "event-form") {
      ev.preventDefault();
      const p = formObj(ev.target);
      await api("/api/events", { method: "POST", body: { ...p, source: "manual" } });
      closeModal();
      await refreshCore();
      render();
    }
    if (ev.target.id === "note-form") {
      ev.preventDefault();
      const p = formObj(ev.target);
      const id = p.id;
      delete p.id;
      if (id) await api(`/api/notes/${id}`, { method: "POST", body: p });
      else await api("/api/notes", { method: "POST", body: p });
      closeModal();
      state.notes = await api("/api/notes");
      render();
    }
    if (ev.target.id === "contact-form") {
      ev.preventDefault();
      const p = formObj(ev.target);
      const id = p.id;
      delete p.id;
      if (id) await api(`/api/contacts/${id}`, { method: "POST", body: p });
      else await api("/api/contacts", { method: "POST", body: p });
      closeModal();
      state.contacts = await api("/api/contacts");
      render();
    }
    if (ev.target.id === "time-form") {
      ev.preventDefault();
      await api("/api/time", { method: "POST", body: formObj(ev.target) });
      closeModal();
      await refreshCore();
      render();
    }
  });
}

async function loadReminders() {
  try {
    const items = await api("/api/reminders");
    const box = $("#reminders");
    if (!items.length) {
      box.classList.add("hidden");
      box.innerHTML = "";
      return;
    }
    box.classList.remove("hidden");
    box.innerHTML = items.map((e) =>
      `<span>${esc(e.title)} · ${esc(fmtDate(e.start_at))}
       <button data-dismiss="${e.id}">Dismiss</button></span>`
    ).join(" · ");
    $$("[data-dismiss]", box).forEach((btn) => {
      btn.addEventListener("click", async () => {
        await api(`/api/events/${btn.dataset.dismiss}/dismiss`, { method: "POST", body: {} });
        loadReminders();
      });
    });
    if (window.Notification && Notification.permission === "granted") {
      items.slice(0, 3).forEach((e) => new Notification("Praecipe", { body: `${e.title} · ${fmtDate(e.start_at)}` }));
    }
  } catch {}
}

async function boot() {
  bindGlobal();
  if (window.Notification && Notification.permission === "default") Notification.requestPermission();
  await refreshCore();
  state.contacts = await api("/api/contacts");
  await loadMail();
  render();
  loadReminders();
  setInterval(renderTimer, 30000);
  setInterval(loadReminders, 60000);
  startMailPoll();
}

boot().catch((err) => {
  $("#app").innerHTML = `<div class="empty error">${esc(err.message)}</div>`;
});
