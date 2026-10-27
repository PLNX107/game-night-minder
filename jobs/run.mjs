// Game Night Minder: scheduled job. Runs every few hours from GitHub Actions.
// Every step is safe to repeat: the database and the email log remember what was already done.
import nodemailer from 'nodemailer';
import { createHash } from 'node:crypto';

const env = k => process.env[k] || '';
const DRY = env('DRY_RUN') !== 'false';            // anything except the word "false" is a dry run
const TZ = env('TIMEZONE') || 'America/New_York';
const BASE = (env('REST_BASE') || env('SUPABASE_URL').replace(/\/$/, '') + '/rest/v1').replace(/\/$/, '');
const KEY = env('SUPABASE_SERVICE_ROLE_KEY');
const SITE = env('SITE_URL').replace(/\/?$/, '/');
const ORGANIZER = env('ORGANIZER_EMAIL');
const NOW = env('FAKE_NOW') ? new Date(env('FAKE_NOW')) : new Date();   // FAKE_NOW is for testing only
const POLL_OPEN_HOUR = 9;                           // local hour on the last Sunday before the poll opens
const SUMMARY_GAP_MS = 12 * 3600e3;                 // at most one organizer summary per 12 hours
const MAX_ATTEMPTS = 3;                             // give up on an address after 3 failed sends
const TEST_MAIL = env('MAIL_TRANSPORT') === 'json'; // test hook: print messages instead of sending

const missing = ['SUPABASE_SERVICE_ROLE_KEY', 'SITE_URL', 'ORGANIZER_EMAIL',
  ...(env('REST_BASE') ? [] : ['SUPABASE_URL']),
  ...(DRY || TEST_MAIL ? [] : ['GMAIL_ADDRESS', 'GMAIL_APP_PASSWORD'])].filter(k => !env(k));
if (missing.length) { console.error('Missing settings: ' + missing.join(', ')); process.exit(1); }

// ---------- database (Supabase REST, service role) ----------
async function db(path, { method = 'GET', body, prefer } = {}) {
  const headers = { 'Content-Type': 'application/json', apikey: KEY };
  if (KEY.startsWith('eyJ')) headers.Authorization = 'Bearer ' + KEY;
  if (prefer) headers.Prefer = prefer;
  const r = await fetch(`${BASE}/${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch {}
  if (!r.ok) throw new Error(`${method} ${path.split('?')[0]} failed: ${(data && data.message) || r.status}`);
  return data;
}
const rpc = (fn, args) => db(`rpc/${fn}`, { method: 'POST', body: args });
const patch = (table, filter, body) => db(`${table}?${filter}`, { method: 'PATCH', body, prefer: 'return=minimal' });

// ---------- dates (all "local" times use TIMEZONE) ----------
const pad = n => String(n).padStart(2, '0');
function localParts(d) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: TZ, year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', hourCycle: 'h23' })
    .formatToParts(d).map(x => [x.type, x.value]));
  return { y: +p.year, m: +p.month, d: +p.day, h: +p.hour };
}
const lastSunday = (y, m) => { const dt = new Date(Date.UTC(y, m, 0)); while (dt.getUTCDay() !== 0) dt.setUTCDate(dt.getUTCDate() - 1); return dt.getUTCDate(); };
const saturdaysOf = (y, m) => { const out = []; for (let d = new Date(Date.UTC(y, m - 1, 1)); d.getUTCMonth() === m - 1; d.setUTCDate(d.getUTCDate() + 1)) if (d.getUTCDay() === 6) out.push(d.toISOString().slice(0, 10)); return out; };
const fmtDate = iso => new Date(iso + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC' });
const fmtMonth = iso => new Date(iso + 'T12:00:00Z').toLocaleDateString('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const fmtTime = t => { if (!t) return ''; const [H, M] = t.split(':').map(Number); return `${H % 12 || 12}:${pad(M)} ${H < 12 ? 'AM' : 'PM'}`; };
const fmtDeadline = ts => new Date(ts).toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', timeZone: TZ });
const today = (t => `${t.y}-${pad(t.m)}-${pad(t.d)}`)(localParts(NOW));

// ---------- email ----------
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
// blocks: strings, or arrays of strings (shown as bullet lists)
function compose(name, blocks, cta) {
  const text = [`Hi ${name},`, ...blocks.map(b => Array.isArray(b) ? b.map(x => '  - ' + x).join('\n') : b),
    ...(cta ? [`${cta.label}: ${cta.url}`] : []), '– Game Night'].join('\n\n');
  const html = '<div style="font-family:system-ui,sans-serif;font-size:16px;line-height:1.5;max-width:34rem">'
    + `<p>Hi ${esc(name)},</p>`
    + blocks.map(b => Array.isArray(b) ? '<ul>' + b.map(x => `<li>${esc(x)}</li>`).join('') + '</ul>' : `<p>${esc(b)}</p>`).join('')
    + (cta ? `<p><a href="${esc(cta.url)}" style="display:inline-block;background:#2f6f5e;color:#fff;padding:.7rem 1.2rem;border-radius:8px;text-decoration:none;font-weight:600">${esc(cta.label)}</a></p>` : '')
    + '<p style="color:#656d76">– Game Night</p></div>';
  return { text, html };
}
const transport = DRY ? null : TEST_MAIL ? nodemailer.createTransport({ jsonTransport: true })
  : nodemailer.createTransport({ host: 'smtp.gmail.com', port: 465, secure: true, auth: { user: env('GMAIL_ADDRESS'), pass: env('GMAIL_APP_PASSWORD') } });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const logEmail = row => db('email_log', { method: 'POST', body: row, prefer: 'return=minimal' });

// 'done' if this email was already sent (or failed too many times), otherwise 'todo'
async function emailState(ev, att, kind) {
  const rows = await db(`email_log?select=status&kind=eq.${kind}&event_id=eq.${ev.id}&attendee_id=eq.${att.id}`);
  if (rows.some(r => r.status === 'sent')) return 'done';
  return rows.filter(r => r.status === 'failed').length >= MAX_ATTEMPTS ? 'done' : 'todo';
}

async function send(ev, att, kind, to, subject, mail) {
  const row = { event_id: ev.id, attendee_id: att ? att.id : null, kind, recipient: to };
  if (DRY) { console.log(`[dry run] ${kind} -> ${to} | ${subject}`); await logEmail({ ...row, status: 'dry_run' }); return true; }
  try {
    const info = await transport.sendMail({ from: `"Game Night" <${env('GMAIL_ADDRESS') || 'test@example.com'}>`, to, replyTo: ORGANIZER, subject, text: mail.text, html: mail.html });
    if (TEST_MAIL) console.log(`--- MAIL to ${to}: ${subject}\n${mail.text}\n---`);
    await logEmail({ ...row, status: 'sent' });
    console.log(`sent ${kind} -> ${to}`);
    if (!TEST_MAIL) await sleep(700);
    return true;
  } catch (e) {
    console.error(`FAILED ${kind} -> ${to}: ${e.message}`);
    await logEmail({ ...row, status: 'failed', error: String(e.message).slice(0, 500) });
    return false;
  }
}

// ---------- data ----------
const activeAttendees = () => db('attendees?select=id,name,email,token&active=eq.true&order=name');
const invitationsOf = ev => db(`invitations?select=*,attendees(id,name,email,token,active)&event_id=eq.${ev.id}`);
const signupsOf = ev => db(`signups?select=role,details,address,attendees(name)&event_id=eq.${ev.id}&order=created_at`);
const respondedIds = async ev => new Set((await db(`ballots?select=attendee_id&event_id=eq.${ev.id}`)).map(b => b.attendee_id));
const link = a => `${SITE}?t=${a.token}`;
const ROLE = { host: 'Host', food: 'Food', beverage: 'Beverages', game: 'Games' };
const hostAddress = (ev, sg) => (sg.find(s => s.role === 'host') || {}).address || ev.location || null;

function summaryBlocks(ev, inv, sg, address) {
  const names = st => inv.filter(i => i.status === st && i.attendees.active).map(i => i.attendees.name);
  const yes = names('yes'), pending = names('pending');
  const blocks = [`When: ${fmtDate(ev.chosen_date)}${ev.start_time ? ' at ' + fmtTime(ev.start_time) : ''}`];
  if (address) blocks.push(`Where: ${address}`, `Map: https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`);
  else blocks.push('Where: the address is shared with guests once they reply yes.');
  if (ev.notes) blocks.push(`Notes: ${ev.notes}`);
  blocks.push(`Coming (${yes.length}): ${yes.join(', ') || 'no one yet'}`);
  if (pending.length) blocks.push(`Haven’t replied yet: ${pending.join(', ')}`);
  blocks.push(Object.entries(ROLE).map(([r, label]) =>
    `${label}: ${sg.filter(s => s.role === r).map(s => s.attendees.name + (s.details ? ` (${s.details})` : '')).join(', ') || 'still needed'}`));
  return blocks;
}

// ---------- step 1: open next month's poll (last Sunday of the month, after 9 AM local) ----------
async function ensureNextPoll(settings) {
  const t = localParts(NOW), ls = lastSunday(t.y, t.m);
  if (!(t.d > ls || (t.d === ls && t.h >= POLL_OPEN_HOUR))) return;
  const [ny, nm] = t.m === 12 ? [t.y + 1, 1] : [t.y, t.m + 1];
  const month = `${ny}-${pad(nm)}-01`;
  if ((await db(`events?select=id&month=eq.${month}`)).length) return;
  if (!(await activeAttendees()).length) { console.log('No active attendees yet; not creating a poll.'); return; }
  if (DRY) { console.log(`[dry run] would create the ${fmtMonth(month)} poll`); return; }
  const [ev] = await db('events', { method: 'POST', prefer: 'return=representation',
    body: { month, poll_closes_at: new Date(NOW.getTime() + settings.poll_window_days * 864e5).toISOString() } });
  await db('date_options', { method: 'POST', prefer: 'return=minimal', body: saturdaysOf(ny, nm).map(d => ({ event_id: ev.id, option_date: d })) });
  console.log(`Created the ${fmtMonth(month)} poll`);
}

// ---------- step 2: poll phase ----------
async function handlePolling(ev, settings) {
  const atts = await activeAttendees();
  for (const a of atts) {
    if (await emailState(ev, a, 'poll_open') === 'done') continue;
    await send(ev, a, 'poll_open', a.email, `Game Night: which Saturday works in ${fmtMonth(ev.month)}?`,
      compose(a.name, [`Let’s pick a date for ${fmtMonth(ev.month)}. Please answer yes or no for each Saturday.`,
        `Voting closes ${fmtDeadline(ev.poll_closes_at)}. While you’re there you can see everyone’s votes, offer to host or bring something, and leave a message.`],
        { label: 'Vote now', url: link(a) }));
  }
  if (NOW < new Date(ev.poll_closes_at)) return;

  const [prog] = await db(`poll_progress?select=*&event_id=eq.${ev.id}`);
  if (prog && prog.majority_reached) {
    if (DRY) { console.log(`[dry run] would lock in the winning date for ${fmtMonth(ev.month)}`); return; }
    const n = await rpc('schedule_event', { p_event_id: ev.id, p_option_id: null });
    console.log(`Locked in the date for ${fmtMonth(ev.month)}; ${n} people invited`);
    const [fresh] = await db(`events?select=*&id=eq.${ev.id}`);
    return handleScheduled(fresh, settings);
  }

  // No majority yet: nudge people who haven't voted, and tell the organizer (once)
  if (ev.reminder_sent_at) return;
  const done = await respondedIds(ev);
  for (const a of atts.filter(a => !done.has(a.id))) {
    if (await emailState(ev, a, 'poll_reminder') === 'done') continue;
    await send(ev, a, 'poll_reminder', a.email, `Reminder: Game Night vote for ${fmtMonth(ev.month)}`,
      compose(a.name, [`We’re still waiting on enough votes to pick a date for ${fmtMonth(ev.month)}. It only takes a minute.`], { label: 'Vote now', url: link(a) }));
  }
  const waiting = atts.filter(a => !done.has(a.id)).map(a => a.name);
  const ok = await send(ev, null, 'organizer_alert', ORGANIZER, `Game Night: no majority yet for ${fmtMonth(ev.month)}`,
    compose('Organizer', [`The voting window has closed but fewer than half of the group has voted (${done.size} of ${atts.length}).`,
      `Reminders went to: ${waiting.join(', ') || 'no one'}.`,
      'The job will keep checking and will lock in the winning date automatically once a majority responds. You can also lock in a date yourself.'],
      { label: 'Open the admin page', url: SITE + 'admin.html' }));
  if (ok && !DRY) await patch('events', `id=eq.${ev.id}`, { reminder_sent_at: NOW.toISOString() });
}

// ---------- step 3: scheduled phase ----------
async function handleScheduled(ev, settings) {
  if (ev.chosen_date < today) return;                       // the game day has passed
  const inv = await invitationsOf(ev), sg = await signupsOf(ev);
  const guests = inv.filter(i => i.attendees.active);

  // 3a. invitations (no address), then unlock the address on the website
  if (!ev.invites_sent_at) {
    let allDone = true;
    for (const i of guests.filter(i => i.status !== 'declined')) {
      const a = i.attendees;
      if (await emailState(ev, a, 'invitation') === 'done') continue;
      const ok = await send(ev, a, 'invitation', a.email, `You’re invited: Game Night on ${fmtDate(ev.chosen_date)}`,
        compose(a.name, ['The date is set.', ...summaryBlocks(ev, inv, sg, null),
          'Please let us know if you can make it, and sign up to host or bring something. Anything you sign up for counts as a yes.'],
          { label: 'Reply and sign up', url: link(a) }));
      if (!ok) allDone = false;
    }
    if (allDone && !DRY) await patch('events', `id=eq.${ev.id}`, { invites_sent_at: NOW.toISOString() });
    return;
  }

  // 3b. reminder to guests who still haven't replied (no address)
  const dueAt = new Date(ev.invites_sent_at).getTime() + settings.invite_reminder_days * 864e5;
  if (NOW.getTime() >= dueAt) {
    for (const i of guests.filter(i => i.status === 'pending')) {
      const a = i.attendees;
      if (await emailState(ev, a, 'invite_reminder') === 'done') continue;
      const ok = await send(ev, a, 'invite_reminder', a.email, `Reminder: are you coming to Game Night on ${fmtDate(ev.chosen_date)}?`,
        compose(a.name, ['We haven’t heard from you yet.', ...summaryBlocks(ev, inv, sg, null),
          'Let us know if you’re coming. The address is shared once you reply yes.'], { label: 'Reply now', url: link(a) }));
      if (ok && !DRY) await patch('invitations', `event_id=eq.${ev.id}&attendee_id=eq.${a.id}`, { reminder_sent_at: NOW.toISOString() });
    }
  }

  // 3c. summary with the address, once per guest who has said yes (including late repliers)
  const address = hostAddress(ev, sg);
  if (address) {
    for (const i of guests.filter(i => i.status === 'yes')) {
      const a = i.attendees;
      if (await emailState(ev, a, 'details') === 'done') continue;
      const ok = await send(ev, a, 'details', a.email, `Game Night details: ${fmtDate(ev.chosen_date)}`,
        compose(a.name, ['Great, you’re in! Here are the details so far.', ...summaryBlocks(ev, inv, sg, address),
          'The page always has the latest list of who’s bringing what, and you can leave messages there.'], { label: 'Open the page', url: link(a) }));
      if (ok && !DRY) await patch('invitations', `event_id=eq.${ev.id}&attendee_id=eq.${a.id}`, { details_sent_at: NOW.toISOString() });
    }
  }

  // 3d. organizer summary, only when something changed (at most every 12 hours)
  const declined = guests.filter(i => i.status === 'declined').map(i => i.attendees.name);
  const digest = createHash('sha256').update(JSON.stringify([
    inv.map(i => [i.attendees.name, i.status]).sort(), sg.map(s => [s.role, s.attendees.name, s.details, s.address])])).digest('hex').slice(0, 16);
  const recently = ev.organizer_summary_at && NOW.getTime() - new Date(ev.organizer_summary_at).getTime() < SUMMARY_GAP_MS;
  if (digest !== ev.organizer_digest && !recently) {
    const ok = await send(ev, null, 'organizer_summary', ORGANIZER, `Game Night summary: ${fmtDate(ev.chosen_date)}`,
      compose('Organizer', [...summaryBlocks(ev, inv, sg, address || 'no host address yet'),
        `Can’t make it: ${declined.join(', ') || 'no one'}.`], { label: 'Open the admin page', url: SITE + 'admin.html' }));
    if (ok && !DRY) await patch('events', `id=eq.${ev.id}`, { organizer_digest: digest, organizer_summary_at: NOW.toISOString() });
  }
}

// ---------- main ----------
console.log(`Game Night job at ${NOW.toISOString()} (${DRY ? 'DRY RUN: no emails, no changes' : 'LIVE'})`);
try {
  const [settings] = await db('app_settings?select=*&id=eq.1');
  await ensureNextPoll(settings);
  const events = await db('events?select=*&status=in.(polling,scheduled)&order=month.desc&limit=3');
  for (const ev of events) {
    try { await (ev.status === 'polling' ? handlePolling(ev, settings) : handleScheduled(ev, settings)); }
    catch (e) { console.error(`Problem with ${ev.month}: ${e.message}`); process.exitCode = 1; }
  }
} catch (e) { console.error(e.message); process.exitCode = 1; }
console.log('Done.');
