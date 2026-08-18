const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
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
  folders: [],
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
  const [matters, events, time, settings, catalog, folders] = await Promise.all([
    api("/api/matters"),
    api("/api/events"),
    api("/api/time"),
    api("/api/settings"),
    api("/api/deadlines/catalog"),
    api("/api/mail/folders"),
  ]);
  state.matters = matters;
  state.events = events;
  state.time = time;
  state.settings = settings;
  state.catalog = catalog;
  state.folders = folders;
  state.timer = time.find((t) => t.running) || null;
  renderTimer();
  renderUnread();
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
  const rail = $("#rail-unread");
  if (unseen) {
    chip.classList.remove("hidden");
    chip.textContent = `${unseen} unread`;
    rail.textContent = `(${unseen})`;
  } else {
    chip.classList.add("hidden");
    rail.textContent = "";
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

function renderMail() {
  const folders = state.folders.map((f) => `
    <button type="button" data-folder="${esc(f.name)}" class="${state.folder === f.name ? "active" : ""}">
      ${esc(folderRoleLabel(f))}
      ${f.unseen ? `<span class="rail-unread">${f.unseen}</span>` : ""}
    </button>`).join("");
  const items = state.mail.map((m) => `
    <article class="list-item ${state.selectedMail === m.id ? "active" : ""} ${m.seen ? "" : "unread"} ${m.flagged ? "flagged" : ""}" data-id="${m.id}">
      <div class="meta">${esc(fmtDate(m.sent_at))} ${m.has_attachments ? "· att" : ""} · ${esc(matterLabel(m.matter_id))}</div>
      <h3>${esc(m.subject || "(no subject)")}</h3>
      <p>${esc(m.from_addr)} — ${esc(m.snippet || "")}</p>
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
        <div class="meta">${esc(msg.from_addr)} → ${esc(msg.to_addr)}${msg.cc_addr ? " · Cc " + esc(msg.cc_addr) : ""} · ${esc(fmtDate(msg.sent_at))}</div>
        <h1>${esc(msg.subject)}</h1>
        ${(msg.attachments || []).map((a) => `<a class="badge file-link" href="/api/attachments/${a.id}">${esc(a.filename)}</a>`).join("")}
        ${suggest}
        ${htmlFrame}
      </div>`;
  }
  return `
    <div class="split mail">
      <div class="folders">
        <div class="toolbar"><strong>Folders</strong></div>
        ${folders || `<button data-folder="INBOX" class="active">Inbox</button><button data-folder="SENT">Sent</button><button data-folder="DRAFTS">Drafts</button>`}
      </div>
      <div class="list">
        <div class="toolbar">
          <strong>${esc(folderRoleLabel({ name: state.folder }))}</strong>
          <span id="flash" class="${/fail|error/i.test(state.status) ? "error" : "ok"}">${esc(state.status)}</span>
        </div>
        ${items || `<div class="empty">No messages in this folder.</div>`}
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
  const s = state.settings;
  const on = (k, d = "0") => (s[k] ?? d) !== "0" && (s[k] ?? d) !== "false";
  return `
    <form class="form-grid" id="settings-form">
      <label>Your name <input name="display_name" value="${esc(s.display_name || "")}"></label>
      <label>Email address <input name="email_address" value="${esc(s.email_address || "")}"></label>
      <label>Provider preset
        <select name="preset" id="preset">
          <option value="">— choose to fill hosts —</option>
          <option value="gmail">Gmail (app password)</option>
          <option value="outlook">Microsoft 365 / Outlook</option>
          <option value="yahoo">Yahoo</option>
          <option value="icloud">iCloud</option>
        </select>
      </label>
      <label>Default billing rate <input name="default_rate" type="number" step="0.01" value="${esc(s.default_rate || "")}"></label>
      <label>IMAP host <input name="imap_host" value="${esc(s.imap_host || "")}"></label>
      <label>IMAP port <input name="imap_port" value="${esc(s.imap_port || "993")}"></label>
      <label>IMAP user <input name="imap_user" value="${esc(s.imap_user || "")}"></label>
      <label>IMAP password <input name="imap_password" type="password" placeholder="${s.imap_password_set ? "unchanged" : ""}"></label>
      <label>SMTP host <input name="smtp_host" value="${esc(s.smtp_host || "")}"></label>
      <label>SMTP port <input name="smtp_port" value="${esc(s.smtp_port || "587")}"></label>
      <label>SMTP user <input name="smtp_user" value="${esc(s.smtp_user || "")}"></label>
      <label>SMTP password <input name="smtp_password" type="password" placeholder="${s.smtp_password_set ? "unchanged" : ""}"></label>
      <label>SMTP security
        <select name="smtp_tls">
          <option value="starttls" ${s.smtp_tls === "starttls" || !s.smtp_tls ? "selected" : ""}>STARTTLS</option>
          <option value="ssl" ${s.smtp_tls === "ssl" ? "selected" : ""}>SSL</option>
        </select>
      </label>
      <label>County / division <input name="county" value="${esc(s.county || "")}" placeholder="Lee County · Family"></label>
      <label class="span-2">Signature (appended to new mail) <textarea name="signature">${esc(s.signature || "")}</textarea></label>
      <label class="span-2"><input type="checkbox" name="auto_docket" ${on("auto_docket", "1") ? "checked" : ""}> Automatically docket dates and Fla. Fam. L. R. P. deadlines found in opened mail</label>
      <label class="span-2"><input type="checkbox" name="auto_download_service" ${on("auto_download_service", "0") ? "checked" : ""}> Automatically download likely service-document URLs when a message is opened</label>
      <div class="span-2">
        <button class="primary" type="submit">Save settings</button>
        <span id="flash"></span>
        <p class="meta">Gmail needs an app password. Microsoft 365 uses the Outlook preset. Praecipe Send/Receives every two minutes once IMAP is saved. Credentials stay on this computer.</p>
      </div>
    </form>`;
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
  openModal(`
    <form class="stack" id="compose-form">
      <h2 style="font-family:var(--serif);margin:0">${esc(prefill.heading || "New Email")}</h2>
      <label>To <input name="to" required value="${esc(prefill.to || "")}" list="people-list"></label>
      <label>Cc <input name="cc" value="${esc(prefill.cc || "")}" list="people-list"></label>
      <label>Bcc <input name="bcc" value="${esc(prefill.bcc || "")}" list="people-list"></label>
      <label>Subject <input name="subject" value="${esc(prefill.subject || "")}"></label>
      <label>Matter ${matterSelect("matter_id", prefill.matter_id || state.message?.matter_id || "")}</label>
      <label>Body <textarea name="body" class="compose-body" required>${esc(prefill.body || (state.settings.signature ? "\n\n" + state.settings.signature : ""))}</textarea></label>
      <label>Attachments <input name="files" type="file" multiple></label>
      <input type="hidden" name="in_reply_to" value="${esc(prefill.in_reply_to || "")}">
      <input type="hidden" name="references" value="${esc(prefill.references || "")}">
      <input type="hidden" name="answered_id" value="${esc(prefill.answered_id || "")}">
      <datalist id="people-list">${state.contacts.map((c) => `<option value="${esc(c.email)}">${esc(c.name)}</option>`).join("")}</datalist>
      <div>
        <button class="primary" type="submit">Send</button>
        <button type="button" id="btn-draft">Save draft</button>
        <button type="button" id="cancel-modal">Cancel</button>
      </div>
    </form>`, true);
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
  const folder = encodeURIComponent(state.folder || "INBOX");
  state.mail = await api(`/api/mail?folder=${folder}&q=${q}`);
  state.folders = await api("/api/mail/folders");
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
  if (!state.message.seen) {
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
  if (htmlFrame && state.message?.body_html) htmlFrame.srcdoc = state.message.body_html;
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
    const payload = formObj(ev.target);
    delete payload.preset;
    await api("/api/settings", { method: "POST", body: payload });
    state.settings = await api("/api/settings");
    setStatus("Settings saved.");
    render();
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
}

function bindGlobal() {
  $$(".rail button").forEach((btn) => {
    btn.addEventListener("click", async () => {
      state.view = btn.dataset.view;
      $$(".rail button").forEach((b) => b.classList.toggle("active", b === btn));
      if (state.view === "notes") state.notes = await api("/api/notes");
      if (state.view === "files") state.files = await api("/api/files");
      if (state.view === "contacts") state.contacts = await api("/api/contacts");
      render();
    });
  });
  $("#btn-sync").addEventListener("click", async () => {
    setStatus("Send/Receive…");
    render();
    try {
      const out = await api("/api/mail/sync", { method: "POST", body: {} });
      await loadMail();
      setStatus(out.ok ? `Updated. ${out.added} new. ${out.unseen || 0} unread.` : (out.error || "Sync failed"));
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
    $$(".rail button").forEach((b) => b.classList.toggle("active", b.dataset.view === "mail"));
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
  setInterval(async () => {
    try {
      await api("/api/mail/sync", { method: "POST", body: {} });
      await loadMail();
      if (state.view === "mail") render();
    } catch {}
  }, 120000);
}

boot().catch((err) => {
  $("#app").innerHTML = `<div class="empty error">${esc(err.message)}</div>`;
});
