// Server-side OAuth token exchange/refresh for Google / Slack / Notion.
//
// The client SECRETS are read from Edge Function Secrets (Project -> Edge
// Functions -> Secrets), set by the project owner in the Supabase dashboard --
// never in this code, the app, or the git repo. The public client IDs are
// hardcoded below (they ship in the app anyway).
//
// Deployed with verify_jwt=false: integrations connect before any Supabase
// sign-in, and the secret stays server-side regardless.

const CLIENTS: Record<string, { id: string; secretEnv: string }> = {
  google: {
    id: "535692663846-t2sdj5v0s0pqv4qcobfm635jkqlh4rfq.apps.googleusercontent.com",
    secretEnv: "GOOGLE_CLIENT_SECRET",
  },
  slack: {
    id: "10744348290480.11302757894647",
    secretEnv: "SLACK_CLIENT_SECRET",
  },
  notion: {
    id: "37bd872b-594c-81c7-b9b7-0037a2dd2625",
    secretEnv: "NOTION_CLIENT_SECRET",
  },
};

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
  const cfg = provider ? CLIENTS[provider] : undefined;
  if (!cfg) return json({ error: "unknown provider" }, 400);

  const clientId = cfg.id;
  const clientSecret = Deno.env.get(cfg.secretEnv);
  if (!clientSecret) return json({ error: `${provider} secret not configured` }, 500);

  let resp: Response;
  try {
    if (provider === "google") {
      const form = new URLSearchParams();
      form.set("client_id", clientId);
      form.set("client_secret", clientSecret);
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
      form.set("client_id", clientId);
      form.set("client_secret", clientSecret);
      form.set("code", body.code ?? "");
      if (body.redirect_uri) form.set("redirect_uri", body.redirect_uri);
      resp = await fetch("https://slack.com/api/oauth.v2.access", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      });
    } else if (provider === "notion") {
      const basic = btoa(`${clientId}:${clientSecret}`);
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
