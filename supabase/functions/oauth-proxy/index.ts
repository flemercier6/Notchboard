import { createClient } from "jsr:@supabase/supabase-js@2";

// Server-side OAuth token exchange/refresh. The client secrets live ONLY here
// (in the locked public.oauth_credentials table, readable by service_role only),
// never in the distributed app or the git repo. The client sends the short-lived
// authorization `code` (or a refresh_token) and gets back the provider's token
// response verbatim. Deployed with verify_jwt=false (integrations connect before
// any Supabase sign-in; the secret stays server-side regardless).
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function json(obj: unknown, status: number): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: Record<string, string>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const provider = body.provider;
  const action = body.action ?? "exchange";
  if (!provider) return json({ error: "missing provider" }, 400);

  const { data: cred, error } = await admin
    .from("oauth_credentials")
    .select("client_id, client_secret")
    .eq("provider", provider)
    .single();
  if (error || !cred) return json({ error: "unknown provider" }, 400);

  let resp: Response;
  try {
    if (provider === "google") {
      const form = new URLSearchParams();
      form.set("client_id", cred.client_id);
      form.set("client_secret", cred.client_secret);
      if (action === "refresh") {
        form.set("grant_type", "refresh_token");
        form.set("refresh_token", body.refresh_token ?? "");
      } else {
        form.set("grant_type", "authorization_code");
        form.set("code", body.code ?? "");
        form.set("redirect_uri", body.redirect_uri ?? "");
        if (body.code_verifier) form.set("code_verifier", body.code_verifier);
      }
      resp = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      });
    } else if (provider === "slack") {
      const form = new URLSearchParams();
      form.set("client_id", cred.client_id);
      form.set("client_secret", cred.client_secret);
      form.set("code", body.code ?? "");
      if (body.redirect_uri) form.set("redirect_uri", body.redirect_uri);
      resp = await fetch("https://slack.com/api/oauth.v2.access", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      });
    } else if (provider === "notion") {
      const basic = btoa(`${cred.client_id}:${cred.client_secret}`);
      resp = await fetch("https://api.notion.com/v1/oauth/token", {
        method: "POST",
        headers: {
          "Authorization": `Basic ${basic}`,
          "Content-Type": "application/json",
          "Notion-Version": "2022-06-28",
        },
        body: JSON.stringify({
          grant_type: "authorization_code",
          code: body.code,
          redirect_uri: body.redirect_uri,
        }),
      });
    } else {
      return json({ error: "unknown provider" }, 400);
    }
  } catch (e) {
    return json({ error: String(e) }, 502);
  }

  const text = await resp.text();
  return new Response(text, {
    status: resp.status,
    headers: { "Content-Type": "application/json" },
  });
});
