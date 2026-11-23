// Hanterar vilka som får ändra schemat. Bara superanvändare får anropa funktionen.
// Körs med service role, så all behörighetskontroll görs här i koden.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return json({ error: "config" }, 500);
  const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "unauthorized" }, 401);
  const { data: who, error: whoErr } = await admin.auth.getUser(token);
  const caller = who?.user;
  if (whoErr || !caller?.email || !caller.email_confirmed_at) return json({ error: "unauthorized" }, 401);
  const me = caller.email.toLowerCase();
  const { data: meRow } = await admin.from("editors").select("role").eq("email", me).maybeSingle();
  if (meRow?.role !== "super") return json({ error: "forbidden" }, 403);

  let body: { action?: string; email?: string; role?: string; rink_ids?: unknown };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const email = String(body.email ?? "").trim().toLowerCase();

  const allUsers = async () => {
    const { data, error } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (error) throw error;
    return data.users;
  };
  // Engångslänk: inbjudan för ett nytt konto, annars en länk för att välja nytt lösenord.
  const makeLink = async (addr: string) => {
    let r = await admin.auth.admin.generateLink({ type: "invite", email: addr });
    if (r.error) r = await admin.auth.admin.generateLink({ type: "recovery", email: addr });
    if (r.error || !r.data?.properties?.hashed_token) throw r.error ?? new Error("no token");
    return { token_hash: r.data.properties.hashed_token, type: r.data.properties.verification_type };
  };

  // Roller som går att dela ut här. Superanvändare läggs bara till direkt i databasen.
  const ROLES = ["editor", "kommun"];
  // Bara hallar som finns släpps igenom. Utan uppgift får planeraren alla hallar.
  const cleanRinks = async (v: unknown) => {
    const { data, error } = await admin.from("rinks").select("id");
    if (error) throw error;
    const all = data.map((r) => r.id as string);
    return Array.isArray(v) ? all.filter((id) => (v as unknown[]).includes(id)) : all;
  };

  try {
    if (body.action === "list") {
      const { data: rows, error } = await admin.from("editors").select("email, role, rink_ids, created_at").order("created_at");
      if (error) throw error;
      const byEmail = new Map((await allUsers()).map((u) => [(u.email ?? "").toLowerCase(), u]));
      return json({
        editors: rows.map((r) => ({
          email: r.email,
          role: r.role,
          rink_ids: r.rink_ids ?? [],
          active: !!byEmail.get(r.email)?.last_sign_in_at,
          me: r.email === me,
        })),
      });
    }
    if (body.action === "invite") {
      if (!EMAIL.test(email) || email.length > 254) return json({ error: "invalid_email" });
      const role = ROLES.includes(String(body.role)) ? String(body.role) : "editor";
      const rink_ids = role === "editor" ? await cleanRinks(body.rink_ids) : [];
      const { error } = await admin.from("editors").upsert({ email, role, rink_ids, invited_by: me }, { onConflict: "email", ignoreDuplicates: true });
      if (error) throw error;
      return json({ email, ...(await makeLink(email)) });
    }
    if (body.action === "update") {
      if (email === me) return json({ error: "self" });
      const { data: row } = await admin.from("editors").select("role").eq("email", email).maybeSingle();
      if (!row) return json({ error: "not_found" });
      if (row.role === "super") return json({ error: "super" });
      if (!ROLES.includes(String(body.role))) return json({ error: "bad_request" }, 400);
      const role = String(body.role);
      const rink_ids = role === "editor" ? await cleanRinks(body.rink_ids) : [];
      const { error } = await admin.from("editors").update({ role, rink_ids }).eq("email", email);
      if (error) throw error;
      return json({ ok: true });
    }
    if (body.action === "link") {
      const { data: row } = await admin.from("editors").select("email").eq("email", email).maybeSingle();
      if (!row) return json({ error: "not_found" });
      return json({ email, ...(await makeLink(email)) });
    }
    if (body.action === "remove") {
      if (email === me) return json({ error: "self" });
      const { data: row } = await admin.from("editors").select("role").eq("email", email).maybeSingle();
      if (!row) return json({ error: "not_found" });
      if (row.role === "super") return json({ error: "super" });
      const { error } = await admin.from("editors").delete().eq("email", email);
      if (error) throw error;
      const user = (await allUsers()).find((u) => (u.email ?? "").toLowerCase() === email);
      if (user) await admin.auth.admin.deleteUser(user.id);
      return json({ ok: true });
    }
    return json({ error: "bad_request" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: "server" }, 500);
  }
});
