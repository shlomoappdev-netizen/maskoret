// Sends one assistant alert to the Android phones of a household's members, through Firebase Cloud Messaging.
//
// Called by the app (any platform) when it finds a new alert in the household's data. The caller must be a member
// of the household. Each alert id goes out once per household, and each user gets at most one notification a day.
// Secrets: FCM_SERVICE_ACCOUNT — the Firebase service account key (the whole JSON file).
import { createClient } from "jsr:@supabase/supabase-js@2";

const DAY_MS = 20 * 60 * 60 * 1000; // "once a day", with slack so a morning alert isn't blocked by yesterday's noon one

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const b64url = (data: ArrayBuffer | string) => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

/** An OAuth access token for FCM, from the service account key. */
async function accessToken(account: { client_email: string; private_key: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" })) + "." + b64url(JSON.stringify({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 600,
  }));
  const pem = account.private_key.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: unsigned + "." + b64url(signature),
    }),
  });
  if (!res.ok) throw new Error("google auth " + res.status);
  return (await res.json()).access_token as string;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: who } = await asUser.auth.getUser();
  const uid = who?.user?.id;
  if (!uid) return json({ error: "not signed in" }, 401);

  let input: Record<string, unknown>;
  try {
    input = await req.json();
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const hid = String(input.household_id ?? "");
  const alertId = String(input.alert_id ?? "");
  const title = String(input.title ?? "").trim().slice(0, 100);
  const body = String(input.body ?? "").trim().slice(0, 300);
  const exclude = String(input.exclude_token ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(hid) || !alertId || alertId.length > 200 || !title) return json({ error: "bad input" }, 400);

  const secret = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!secret) return json({ error: "push is not set up" }, 503);
  const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: members } = await db.from("household_members").select("user_id").eq("household_id", hid);
  const users = (members ?? []).map((m) => m.user_id as string);
  if (!users.includes(uid)) return json({ error: "not a member" }, 403);

  // Who can get it now: members with a phone, who didn't get a notification in the last day.
  const { data: tokenRows } = await db.from("push_tokens").select("token,user_id").in("user_id", users);
  const { data: states } = await db.from("push_state").select("user_id,last_push_at").in("user_id", users);
  const recent = new Set((states ?? [])
    .filter((s) => Date.now() - new Date(s.last_push_at as string).getTime() < DAY_MS).map((s) => s.user_id as string));
  const targets = (tokenRows ?? []).filter((t) => t.token !== exclude && !recent.has(t.user_id as string));
  if (targets.length === 0) return json({ sent: 0, reason: "nobody to notify" });

  // Each alert once per household.
  const { error: seen } = await db.from("push_alerts").insert({ household_id: hid, alert_id: alertId });
  if (seen) return json({ sent: 0, reason: "already sent" });

  const account = JSON.parse(secret);
  const token = await accessToken(account);
  let sent = 0;
  const notified = new Set<string>();
  for (const t of targets) {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token: t.token,
          notification: { title, body },
          data: { alert_id: alertId },
          android: { notification: { channel_id: "assistant" } },
        },
      }),
    });
    if (res.ok) {
      sent++;
      notified.add(t.user_id as string);
    } else if (res.status === 404 || res.status === 400) {
      // The app was removed from that phone (or the token is no longer valid).
      await db.from("push_tokens").delete().eq("token", t.token);
    }
  }
  if (notified.size > 0) {
    await db.from("push_state").upsert([...notified].map((u) => ({ user_id: u, last_push_at: new Date().toISOString() })));
  }
  return json({ sent });
});
