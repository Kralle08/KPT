// KPT – verschickt die Push-Erinnerungen. Läuft automatisch über GitHub Actions
// (.github/workflows/erinnerungen.yml): mittwochs nachmittags und donnerstags früh.
//
//   mittwoch    an alle, die sich für Freitag noch nicht an- oder abgemeldet haben
//   donnerstag  an die Köche: für wie viele Portionen eingekauft wird
//   test        Probe-Mitteilung an alle Geräte mit eingeschalteter Erinnerung

const berlin = (d = new Date()) => {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Berlin", year: "numeric", month: "2-digit", day: "2-digit", weekday: "short" }).formatToParts(d).map(x => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, weekday: p.weekday };
};
const addDays = (iso, n) => { const d = new Date(iso + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const nextFriday = iso => addDays(iso, (5 - new Date(iso + "T12:00:00Z").getUTCDay() + 7) % 7);
export const modeFor = weekday => ({ Wed: "mittwoch", Thu: "donnerstag" }[weekday] || null);

// Reine Logik: wer bekommt welche Nachricht? (ohne Netz, damit sie sich testen lässt)
export function plan(mode, { meal, rsvps, members }) {
  const active = members.filter(m => m.active), name = id => members.find(m => m.id === id)?.name || "jemand";
  if (mode === "test") return active.map(m => ({ user_id: m.id, title: "KPT: Probe-Erinnerung", body: "Die Erinnerungen funktionieren auf diesem Gerät.", tag: "kpt-test" }));
  if (!meal) return [];
  const cooks = [meal.cook1, meal.cook2].filter(Boolean), wer = cooks.map(name).join(" & ");
  if (mode === "mittwoch") {
    const answered = new Set(rsvps.map(r => r.user_id));
    return active.filter(m => !answered.has(m.id) && !cooks.includes(m.id)).map(m => ({
      user_id: m.id, tag: "kpt-anmeldung", title: "KPT: Isst du am Freitag mit?",
      body: `${meal.title ? `Es gibt ${meal.title}, ` : ""}${wer} ${cooks.length > 1 ? "kochen" : "kocht"}. Bitte bis heute 23:59 Uhr an- oder abmelden.`
    }));
  }
  if (mode === "donnerstag") {
    const yes = rsvps.filter(r => r.coming), guests = yes.reduce((n, r) => n + (r.guests || 0), 0), total = yes.length + guests;
    return cooks.filter(id => active.some(m => m.id === id)).map(id => ({
      user_id: id, tag: "kpt-einkauf", title: `KPT: Einkaufen für ${total} ${total === 1 ? "Portion" : "Portionen"}`,
      body: `Für Freitag sind ${yes.length} ${yes.length === 1 ? "Mitglied" : "Mitglieder"}${guests ? ` und ${guests} ${guests === 1 ? "Gast" : "Gäste"}` : ""} angemeldet. Die Anmeldung ist geschlossen.`
    }));
  }
  return [];
}

async function main() {
  const env = process.env, need = ["SUPABASE_URL", "SUPABASE_SECRET_KEY", "VAPID_PUBLIC_KEY", "VAPID_PRIVATE_KEY", "VAPID_CONTACT"];
  const missing = need.filter(k => !env[k]);
  if (missing.length) throw new Error("Es fehlen Einträge unter Settings → Secrets: " + missing.join(", "));

  const now = berlin(), mode = (env.MODUS || "").trim() || modeFor(now.weekday);
  if (!mode) { console.log(`Heute (${now.weekday}) ist nichts zu tun.`); return; }
  const day = nextFriday(now.date);
  console.log(`Modus: ${mode}, Freitag: ${day}`);

  const { createClient } = await import("@supabase/supabase-js");
  const webpush = (await import("web-push")).default;
  const sb = createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const get = async q => { const { data, error } = await q; if (error) throw new Error("Datenbank: " + error.message); return data; };

  const [members, meals, rsvps, subs] = await Promise.all([
    get(sb.from("profiles").select("id,name,active")),
    get(sb.from("meals").select("*").eq("day", day)),
    get(sb.from("rsvps").select("*").eq("day", day)),
    get(sb.from("push_subscriptions").select("*"))
  ]);
  const todo = plan(mode, { meal: meals[0], rsvps, members });
  console.log(`${todo.length} Mitglied(er) zu benachrichtigen, ${subs.length} Gerät(e) mit Erinnerung.`);

  const contact = env.VAPID_CONTACT.includes(":") ? env.VAPID_CONTACT : "mailto:" + env.VAPID_CONTACT;
  webpush.setVapidDetails(contact, env.VAPID_PUBLIC_KEY, env.VAPID_PRIVATE_KEY);
  let sent = 0, failed = 0;
  for (const t of todo) {
    for (const s of subs.filter(x => x.user_id === t.user_id)) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ title: t.title, body: t.body, tag: t.tag }), { TTL: 6 * 3600 });
        sent++;
      } catch (e) {
        failed++;
        if (e.statusCode === 404 || e.statusCode === 410) await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint);  // Gerät hat die Erinnerung abbestellt
        else console.log("Fehler beim Senden:", e.statusCode || e.message);
      }
    }
  }
  console.log(`Gesendet: ${sent}, fehlgeschlagen: ${failed}`);
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch(e => { console.error(e.message); process.exit(1); });
