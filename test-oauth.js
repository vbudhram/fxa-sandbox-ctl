const crypto = require("crypto");

function HKDF(ikm, salt, info, len) {
  const hmac1 = crypto.createHmac("sha256", salt || Buffer.alloc(32));
  hmac1.update(ikm);
  const prk = hmac1.digest();
  let t = Buffer.alloc(0), okm = Buffer.alloc(0), i = 0;
  while (okm.length < len) {
    i++;
    const h = crypto.createHmac("sha256", prk);
    h.update(Buffer.concat([t, Buffer.from(info, "utf8"), Buffer.from([i])]));
    t = h.digest();
    okm = Buffer.concat([okm, t]);
  }
  return okm.subarray(0, len);
}

function hawkHeader(tokenId, reqHMACkey, method, url, payload, ct) {
  const ts = Math.floor(Date.now() / 1000);
  const nonce = crypto.randomBytes(6).toString("hex");
  const u = new URL(url);
  const ph = crypto.createHash("sha256")
    .update("hawk.1.payload\n" + (ct||"") + "\n" + (payload||"") + "\n")
    .digest("base64");
  const mac = crypto.createHmac("sha256", Buffer.from(reqHMACkey, "hex"))
    .update(
      "hawk.1.header\n" + ts + "\n" + nonce + "\n" + method + "\n" +
      u.pathname + u.search + "\n" + u.hostname + "\n" + (u.port||"80") +
      "\n" + ph + "\n\n"
    )
    .digest("base64");
  return `Hawk id="${tokenId}", ts="${ts}", nonce="${nonce}", hash="${ph}", mac="${mac}"`;
}

async function main() {
  const email = "pt" + Date.now() + "@restmail.net";
  const authPW = crypto.randomBytes(32).toString("hex");

  const r = await fetch("http://localhost:9000/v1/account/create", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, authPW, preVerified: true }),
  });
  const s = await r.json();
  console.log("Account:", s.uid);

  const st = Buffer.from(s.sessionToken, "hex");
  const d = HKDF(st, "", "identity.mozilla.com/picl/v1/sessionToken", 96);
  const tokenId = d.subarray(0,32).toString("hex");
  const key = d.subarray(32,64).toString("hex");

  // Test session status first
  const auth1 = hawkHeader(tokenId, key, "GET", "http://localhost:9000/v1/session/status", "", "");
  const sr = await fetch("http://localhost:9000/v1/session/status", {
    headers: { "Authorization": auth1 },
  });
  console.log("Session status:", sr.status, await sr.text());

  // Now OAuth token
  const payload = JSON.stringify({
    grant_type: "fxa-credentials",
    client_id: "dcdb5ae7add825d2",
    scope: "profile"
  });
  console.log("\nPayload:", payload);

  const auth2 = hawkHeader(tokenId, key, "POST", "http://localhost:9000/v1/oauth/token", payload, "application/json");

  const t0 = Date.now();
  const or = await fetch("http://localhost:9000/v1/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": auth2 },
    body: payload,
  });
  const elapsed = Date.now() - t0;
  const result = await or.json();
  console.log("\nOAuth response (" + elapsed + "ms):", or.status);
  console.log(JSON.stringify(result).substring(0, 300));

  if (or.ok) {
    // Second request
    const auth3 = hawkHeader(tokenId, key, "POST", "http://localhost:9000/v1/oauth/token", payload, "application/json");
    const t1 = Date.now();
    const or2 = await fetch("http://localhost:9000/v1/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": auth3 },
      body: payload,
    });
    const result2 = await or2.json();
    console.log("\nSecond OAuth (" + (Date.now() - t1) + "ms):", or2.status);
    console.log(JSON.stringify(result2).substring(0, 200));
  }
}
main().catch(e => { console.error(e); process.exit(1); });
