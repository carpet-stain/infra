// Fronts the IAM-gated agent-memory Cloud Run Service (ADR-0031, #323).
// Mints a Google ID token from a service-account self-signed JWT, forwards
// it as X-Serverless-Authorization (the header Cloud Run's IAM check
// reads), and leaves Authorization — src/auth.ts's own per-role bearer,
// ADR-0046 — untouched. UNVERIFIED: #323's checkpoints 2 and 3 (a real
// fetch() against a live origin, the deny-path flood) have not run.

const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const TOKEN_TTL_SECONDS = 3600;
// Re-mint 5 min before Google's own 1h expiry, not at it — a request that
// lands mid-refresh must never race an already-expired token.
const CACHE_MARGIN_SECONDS = 300;

// Module-scope cache (Phase 4's "~55 min in module scope") — per-isolate,
// not shared across Cloudflare's edge; the Cache API is a deliberate
// deferral until cross-isolate re-minting is actually observed.
let cachedToken = null; // { idToken, expiresAtEpochSeconds }

function base64UrlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem) {
  const base64 = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function signJwt(claims, privateKeyPem) {
  const encoder = new TextEncoder();
  const encodedHeader = base64UrlEncode(encoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const encodedClaims = base64UrlEncode(encoder.encode(JSON.stringify(claims)));
  const signingInput = `${encodedHeader}.${encodedClaims}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(signingInput));
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

// Self-signed-JWT → ID-token exchange (no google-auth library available in
// Workers) — target_audience, not scope, is what makes this an ID-token
// request rather than an access-token one.
async function mintIdToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAtEpochSeconds - CACHE_MARGIN_SECONDS > now) {
    return cachedToken.idToken;
  }

  const serviceAccount = JSON.parse(env.GCP_SA_KEY_JSON);
  const assertion = await signJwt(
    {
      iss: serviceAccount.client_email,
      sub: serviceAccount.client_email,
      aud: TOKEN_ENDPOINT,
      iat: now,
      exp: now + TOKEN_TTL_SECONDS,
      target_audience: env.ORIGIN_URL,
    },
    serviceAccount.private_key
  );

  const response = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(`token endpoint returned ${response.status}: ${await response.text()}`);
  }

  const { id_token: idToken } = await response.json();
  cachedToken = { idToken, expiresAtEpochSeconds: now + TOKEN_TTL_SECONDS };
  return idToken;
}

export default {
  async fetch(request, env) {
    let idToken;
    try {
      idToken = await mintIdToken(env);
    } catch (err) {
      // Distinguishable from the origin's own errors (dotfiles#636's
      // edge-vs-endpoint split) via status + X-Edge-Error, not just 502.
      return new Response(`agent-memory edge: token mint failed — ${err.message}`, {
        status: 502,
        headers: { "X-Edge-Error": "token-mint-failed" },
      });
    }

    const requestUrl = new URL(request.url);
    const targetUrl = new URL(env.ORIGIN_URL);
    targetUrl.pathname = requestUrl.pathname;
    targetUrl.search = requestUrl.search;

    const headers = new Headers(request.headers);
    headers.set("X-Serverless-Authorization", `Bearer ${idToken}`);

    const init = { method: request.method, headers };
    if (request.body) {
      init.body = request.body;
      init.duplex = "half"; // required whenever a Request carries a stream body
    }

    try {
      return await fetch(new Request(targetUrl.toString(), init));
    } catch (err) {
      return new Response(`agent-memory edge: origin fetch failed — ${err.message}`, {
        status: 502,
        headers: { "X-Edge-Error": "origin-fetch-failed" },
      });
    }
  },
};
