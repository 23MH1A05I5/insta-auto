// ════════════════════════════════════════════════════════════════════════════
// InstaAuto — Production Instagram Automation Server
// Structured Architecture Compliant with Meta Instagram Platform Rules
// ════════════════════════════════════════════════════════════════════════════
require("dotenv").config();

const express = require("express");
const cors = require("cors");
const path = require("path");
const fs = require("fs");

const { connectDatabase } = require("./config/database");
const InstagramService = require("./services/instagramService");
const { GRAPH_API_BASE } = require("./config/instagramRules");

const app = express();
const PORT = process.env.PORT || 3000;
const APP_BASE_URL = process.env.APP_BASE_URL || `http://localhost:${PORT}`;

// ── Connect MongoDB ──────────────────────────────────────────────────────────
connectDatabase();

// ── CORS Configuration ────────────────────────────────────────────────────────
const allowedOrigins = (process.env.ALLOWED_ORIGINS || "http://localhost:*,http://127.0.0.1:*")
  .split(",")
  .map((o) => o.trim());

app.use(
  cors({
    origin: (origin, cb) => {
      if (!origin) return cb(null, true);
      if (
        origin.includes("ngrok-free.dev") ||
        origin.includes("ngrok.io") ||
        origin.includes("ngrok-free.app") ||
        origin.includes("localhost") ||
        origin.includes("127.0.0.1")
      ) {
        return cb(null, true);
      }
      const match = allowedOrigins.some((pat) => {
        if (pat === "*") return true;
        if (pat.includes("*")) {
          const re = new RegExp("^" + pat.replace(/\*/g, ".*") + "$");
          return re.test(origin);
        }
        return pat === origin;
      });
      cb(null, match ? true : false);
    },
    credentials: true,
  })
);

// ── Request Logger & JSON Parser with Raw Body for Meta Webhook HMAC ──────────
app.use((req, res, next) => {
  // Only log non-static asset requests
  if (!req.url.startsWith("/assets") && !req.url.endsWith(".js") && !req.url.endsWith(".png")) {
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  }
  next();
});

app.use(
  express.json({
    verify: (req, res, buf) => {
      // Store raw buffer for Meta X-Hub-Signature-256 HMAC verification
      req.rawBody = buf;
    },
  })
);

// ── Core Routes ───────────────────────────────────────────────────────────────
app.use("/api/auth", require("./routes/auth"));
app.use("/api/instagram", require("./routes/instagram"));
app.use("/api/automations", require("./routes/automations"));
app.use("/api/activity", require("./routes/activity"));
app.use("/api/analytics", require("./routes/activity"));

// Meta Webhook endpoint (GET handshake verification & POST realtime event ingestion)
app.use("/webhook", require("./routes/webhook"));

// Meta OAuth callback redirect
app.use("/auth", require("./routes/instagram"));

// Legacy /test-comment alias for backwards compatibility
app.post("/test-comment", (req, res, next) => {
  req.url = "/test-comment";
  require("./routes/webhook")(req, res, next);
});

// ── Diagnostic & Compliance Endpoints ─────────────────────────────────────────
app.get("/health", (req, res) => {
  res.json({ status: "healthy", timestamp: new Date().toISOString() });
});

app.get("/status", (req, res) => {
  const tokenSet = Boolean(process.env.INSTAGRAM_ACCESS_TOKEN && process.env.INSTAGRAM_ACCESS_TOKEN.length > 10);
  res.json({
    server: "running",
    architecture: "structured_instagram_rules",
    mode: process.env.DRY_RUN === "false" ? "LIVE" : "DRY_RUN",
    public_reply: process.env.ENABLE_PUBLIC_REPLY === "true" ? "enabled" : "disabled",
    private_reply: process.env.ENABLE_PRIVATE_REPLY === "true" ? "enabled" : "disabled",
    token_set: tokenSet,
    product: `${process.env.PRODUCT_NAME || "Product"} @ ${process.env.CURRENCY || "Rs. "}${process.env.PRODUCT_PRICE || "499"}`,
    rules: {
      anti_spam_jitter: "active (2-4.5s)",
      seven_day_window_enforced: true,
      one_dm_per_comment_enforced: true,
      meta_signature_verified: true,
    },
  });
});

app.get("/verify-token", async (req, res) => {
  const token = process.env.INSTAGRAM_ACCESS_TOKEN;
  if (!token) return res.status(400).json({ ok: false, reason: "INSTAGRAM_ACCESS_TOKEN not set" });
  const result = await InstagramService.verifyToken(token);
  return res.status(result.ok ? 200 : 401).json(result);
});

// ── Legal & Compliance Pages Required by Meta ─────────────────────────────
app.get("/privacy", (req, res) =>
  res.send(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Privacy Policy - InstaAuto</title><style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;max-width:760px;margin:40px auto;padding:0 20px;line-height:1.7;color:#333;}h1{color:#1e293b;margin-bottom:4px;}h2{color:#475569;margin-top:32px;font-size:18px;}a{color:#7c3aed;}.last-updated{color:#888;font-size:13px;margin-top:0;}footer{margin-top:40px;padding-top:20px;border-top:1px solid #e5e7eb;color:#888;font-size:12px;}</style></head><body>
<h1>Privacy Policy</h1><p class="last-updated">Last Updated: October 2026</p>
<p>InstaAuto (&ldquo;we&rdquo;, &ldquo;our&rdquo;, &ldquo;the Service&rdquo;) is an automated social media tool designed to help Instagram Professional account holders interact with their audience through automated comment replies and direct messages. We are committed to protecting your privacy and operating in full compliance with Meta Platform Terms and applicable privacy law including GDPR and CCPA.</p>
<h2>1. Information We Collect</h2>
<p>We only access data that you explicitly authorize via Meta&rsquo;s official Instagram Graph API OAuth flow:</p><ul><li><strong>Instagram Account ID &amp; Username</strong> &mdash; to identify your account</li><li><strong>Comments on your posts</strong> &mdash; to enable automated comment reply features</li><li><strong>Access Token</strong> &mdash; stored encrypted, used to call the Instagram API on your behalf</li></ul><p>We do <strong>not</strong> access your personal messages inbox, followers list, post content, or any data outside the permissions explicitly granted.</p>
<h2>2. How We Use Your Data</h2>
<p>We use your data solely to provide the InstaAuto service you configure: automatically replying to Instagram comments and sending one-time DMs triggered by those comments. We do not sell, rent, share, or use your data for advertising or profiling of any kind.</p>
<h2>3. Data Sharing</h2>
<p>We do not share your personal data with third parties. API calls are made directly to Meta&rsquo;s servers on your behalf using only your authorized access token.</p>
<h2>4. Data Retention</h2>
<p>We retain your data only as long as your account is active. Activity logs are retained for up to 90 days for debugging purposes, then automatically deleted. You may request immediate deletion at any time (see Section 6).</p>
<h2>5. Security</h2>
<p>Access tokens are stored using encryption at rest. Webhook payloads are verified using Meta&rsquo;s X-Hub-Signature-256 HMAC before processing. We implement industry-standard security practices.</p>
<h2>6. Your Rights &amp; Data Deletion</h2>
<p>You have the right to access, correct, and delete your data at any time:</p><ul><li><strong>In-app:</strong> Go to Profile &rarr; Settings &rarr; Delete Account to remove all your data immediately.</li><li><strong>Via Instagram:</strong> Settings &amp; Privacy &rarr; Website Permissions &rarr; Apps and Websites &rarr; Remove InstaAuto. This immediately invalidates your token and stops all automations.</li><li><strong>By email:</strong> Contact support@instaauto.app with your Instagram handle for a complete data deletion request.</li></ul>
<h2>7. GDPR Compliance (EU/EEA Users)</h2>
<p>If you are located in the EU/EEA, you have rights under GDPR including the right to access, rectification, erasure, restriction of processing, data portability, and to object to processing. To exercise any of these rights, contact support@instaauto.app.</p>
<h2>8. CCPA Compliance (California Residents)</h2>
<p>California residents have the right to know what personal information is collected, the right to delete personal information, and the right to opt-out of sale (we do not sell data). To exercise these rights, contact support@instaauto.app.</p>
<h2>9. Changes to This Policy</h2>
<p>We may update this policy. If we make material changes, we will notify you via the app or email. Continued use of InstaAuto after changes constitutes acceptance.</p>
<h2>10. Contact</h2>
<p>Email: <a href="mailto:support@instaauto.app">support@instaauto.app</a></p>
<footer>InstaAuto &mdash; Compliant with Meta Platform Terms &amp; Instagram Graph API Policies</footer>
</body></html>`)
);

app.get("/terms", (req, res) =>
  res.send(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Terms of Service - InstaAuto</title><style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;max-width:760px;margin:40px auto;padding:0 20px;line-height:1.7;color:#333;}h1{color:#1e293b;}h2{color:#475569;margin-top:28px;font-size:18px;}.last-updated{color:#888;font-size:13px;}footer{margin-top:40px;padding-top:20px;border-top:1px solid #e5e7eb;color:#888;font-size:12px;}</style></head><body>
<h1>Terms of Service</h1><p class="last-updated">Last Updated: October 2026</p>
<h2>1. Acceptance</h2><p>By creating an account or connecting your Instagram account to InstaAuto, you agree to these Terms of Service and the <a href="/privacy">Privacy Policy</a>. You also agree to comply with Meta&rsquo;s <a href="https://developers.facebook.com/terms/" target="_blank">Platform Terms</a> and Instagram&rsquo;s <a href="https://help.instagram.com/581066165581870" target="_blank">Community Guidelines</a>.</p>
<h2>2. Eligibility</h2><p>InstaAuto is available only to owners of Instagram <strong>Professional (Business or Creator)</strong> accounts. Personal accounts are not supported as they lack the required Graph API permissions.</p>
<h2>3. Permitted Use</h2><p>You may use InstaAuto only for legitimate business interactions with your own Instagram followers. Prohibited uses include: spam, harassment, impersonation, deceptive practices, bulk unsolicited messaging, and any use that violates Instagram Community Guidelines or Meta Platform Terms.</p>
<h2>4. Meta Platform Compliance</h2><p>InstaAuto operates within Meta&rsquo;s platform rules including: the 7-day private reply window, one DM per comment trigger, and anti-spam messaging requirements. Violations of Meta&rsquo;s policies by users may result in account suspension by Meta and termination of InstaAuto access.</p>
<h2>5. Service Availability</h2><p>InstaAuto is provided &ldquo;as is&rdquo;. We do not guarantee uninterrupted service as we depend on Meta&rsquo;s API availability. We are not responsible for API downtime, rate limit enforcement, or changes to Meta&rsquo;s platform policies.</p>
<h2>6. Account Termination</h2><p>You may disconnect InstaAuto at any time via the app&rsquo;s Profile &rarr; Settings, or by removing the app in Instagram&rsquo;s App and Website settings. We may suspend your access if we detect violations of these terms.</p>
<h2>7. Contact</h2><p>support@instaauto.app</p>
<footer>InstaAuto &mdash; Compliant with Meta Platform Terms &amp; Instagram Graph API Policies</footer>
</body></html>`)
);

app.get("/data-deletion", (req, res) =>
  res.send(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Data Deletion - InstaAuto</title><style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;max-width:760px;margin:40px auto;padding:0 20px;line-height:1.7;color:#333;}h1{color:#1e293b;}ol{line-height:2;}a{color:#7c3aed;}</style></head><body>
<h1>User Data Deletion Instructions</h1>
<p>InstaAuto gives you full control over your data. To delete your data and stop all automations:</p>
<h2>Option 1 — Delete via InstaAuto App</h2><ol><li>Open the InstaAuto app and go to <strong>Profile &rarr; Settings</strong></li><li>Tap <strong>Delete My Account &amp; All Data</strong></li><li>Confirm — all your data including activity logs and tokens will be permanently deleted within 72 hours.</li></ol>
<h2>Option 2 — Revoke via Instagram</h2><ol><li>Open Instagram and go to <strong>Settings and Privacy</strong></li><li>Tap <strong>Website Permissions &rarr; Apps and Websites</strong></li><li>Find <strong>InstaAuto</strong> and tap <strong>Remove</strong></li><li>Your access token is immediately invalidated and all automations stop. Contact support@instaauto.app to request deletion of stored activity logs.</li></ol>
<h2>Option 3 — Email Request</h2><p>Email <a href="mailto:support@instaauto.app">support@instaauto.app</a> with your Instagram username. We will delete all associated data within 30 days and confirm via email.</p>
<p><strong>Data Deletion Callback URL:</strong> <code>${process.env.APP_BASE_URL || 'https://your-domain.com'}/data-deletion-callback</code></p>
</body></html>`)
);

// ── Meta Required: POST /data-deletion-callback ───────────────────────────────
// Meta sends a signed request here when user removes the app from Instagram.
// Must return { url, confirmation_code } per Meta spec.
app.post("/data-deletion-callback", async (req, res) => {
  const crypto = require("crypto");
  const { signed_request } = req.body || {};
  let igUserId = null;

  if (signed_request) {
    try {
      const [sigB64, payloadB64] = signed_request.split(".");
      const expectedSig = crypto
        .createHmac("sha256", process.env.INSTAGRAM_APP_SECRET || "")
        .update(payloadB64)
        .digest("base64url");

      if (expectedSig === sigB64) {
        const payload = JSON.parse(Buffer.from(payloadB64, "base64url").toString());
        igUserId = payload.user_id;
      } else {
        console.warn("[DataDeletion] Invalid signed_request signature");
      }
    } catch (e) {
      console.warn("[DataDeletion] Failed to parse signed_request:", e.message);
    }
  }

  // Delete the user's data
  if (igUserId) {
    try {
      const User = require("./models/User");
      const Activity = require("./models/Activity");
      // Clear Instagram token and data
      await User.updateMany(
        { "instagram.userId": igUserId },
        {
          $set: {
            "instagram.accessToken": null,
            "instagram.userId": null,
            "instagram.username": null,
            "instagram.tokenExpiry": null,
          },
        }
      );
      // Delete activity logs for this IG user
      await Activity.deleteMany({ igUserId });
      console.log(`[DataDeletion] Deleted data for IG user ${igUserId}`);
    } catch (e) {
      console.error("[DataDeletion] DB error:", e.message);
    }
  }

  const confirmationCode = `DEL-${Date.now()}-${igUserId || "unknown"}`;
  return res.json({
    url: `${APP_BASE_URL}/data-deletion?code=${confirmationCode}`,
    confirmation_code: confirmationCode,
  });
});

// ── Meta Required: POST /deauthorize ─────────────────────────────────────────
// Called by Meta when a user removes the app from their Instagram permissions.
// Must stop all processing for that user immediately.
app.post("/deauthorize", async (req, res) => {
  const crypto = require("crypto");
  const { signed_request } = req.body || {};
  let igUserId = null;

  if (signed_request) {
    try {
      const [sigB64, payloadB64] = signed_request.split(".");
      const expectedSig = crypto
        .createHmac("sha256", process.env.INSTAGRAM_APP_SECRET || "")
        .update(payloadB64)
        .digest("base64url");

      if (expectedSig === sigB64) {
        const payload = JSON.parse(Buffer.from(payloadB64, "base64url").toString());
        igUserId = payload.user_id;
      }
    } catch (e) {
      console.warn("[Deauthorize] Failed to parse signed_request:", e.message);
    }
  }

  if (igUserId) {
    try {
      const User = require("./models/User");
      // Invalidate token — automations will stop processing since token is null
      await User.updateMany(
        { "instagram.userId": igUserId },
        {
          $set: {
            "instagram.accessToken": null,
            "instagram.tokenExpiry": null,
          },
        }
      );
      console.log(`[Deauthorize] Revoked access for IG user ${igUserId}`);
    } catch (e) {
      console.error("[Deauthorize] DB error:", e.message);
    }
  }

  return res.sendStatus(200);
});

// ── Meta App Review Info (self-diagnostic for submission) ─────────────────────
app.get("/meta-review-info", (req, res) => {
  res.json({
    app_name: "InstaAuto",
    permissions_used: [
      { permission: "instagram_business_basic", purpose: "Read connected user's Instagram profile ID and username" },
      { permission: "instagram_business_manage_comments", purpose: "Read comments on user's posts and publish automated replies" },
      { permission: "instagram_business_manage_messages", purpose: "Send one private DM triggered by a comment, within the 7-day Meta policy window" },
    ],
    compliance: {
      privacy_policy_url: `${APP_BASE_URL}/privacy`,
      terms_url: `${APP_BASE_URL}/terms`,
      data_deletion_url: `${APP_BASE_URL}/data-deletion`,
      data_deletion_callback: `${APP_BASE_URL}/data-deletion-callback`,
      deauthorize_callback: `${APP_BASE_URL}/deauthorize`,
      webhook_url: `${APP_BASE_URL}/webhook`,
      seven_day_window_enforced: true,
      one_dm_per_comment_enforced: true,
      hmac_webhook_verification: true,
      anti_spam_jitter: "2000-4500ms",
    },
  });
});

app.get("/download-apk", (req, res) => {
  const debugApk = path.join(__dirname, "../frontend/build/app/outputs/flutter-apk/app-debug.apk");
  const releaseApk = path.join(__dirname, "../frontend/build/app/outputs/flutter-apk/app-release.apk");
  if (fs.existsSync(debugApk)) return res.download(debugApk, "InstaAuto.apk");
  if (fs.existsSync(releaseApk)) return res.download(releaseApk, "InstaAuto.apk");
  return res.status(404).send("APK is currently building. Please refresh in a moment!");
});

// ── Static & Flutter Web App Serving ──────────────────────────────────────────
const webBuildPath = path.join(__dirname, "../frontend/build/web");
if (fs.existsSync(webBuildPath)) {
  console.log(`📱 Serving Flutter Web UI from: ${webBuildPath}`);
  app.use(express.static(webBuildPath, {
    setHeaders: (res) => {
      res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
      res.setHeader("Pragma", "no-cache");
      res.setHeader("Expires", "0");
    }
  }));
} else {
  app.get("/", (req, res) => {
    res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>InstaAuto Technologies — Automated Instagram Engagement & Direct Messaging</title>
  <meta name="description" content="InstaAuto Technologies provides official, compliant automation for Instagram comment replies and private direct messages for creators and businesses.">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-dark: #0b0f19;
      --card-bg: rgba(23, 32, 54, 0.75);
      --card-border: rgba(255, 255, 255, 0.08);
      --accent-purple: #8b5cf6;
      --accent-pink: #ec4899;
      --accent-blue: #3b82f6;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background-color: var(--bg-dark);
      color: var(--text-main);
      line-height: 1.6;
      min-height: 100vh;
      overflow-x: hidden;
    }
    .gradient-mesh {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: radial-gradient(circle at 20% 15%, rgba(139, 92, 246, 0.18) 0%, transparent 45%),
                  radial-gradient(circle at 80% 25%, rgba(236, 72, 153, 0.15) 0%, transparent 40%),
                  radial-gradient(circle at 50% 80%, rgba(59, 130, 246, 0.12) 0%, transparent 50%);
      z-index: -1;
      pointer-events: none;
    }
    nav {
      max-width: 1140px;
      margin: 0 auto;
      padding: 24px 20px;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .logo {
      font-weight: 800;
      font-size: 22px;
      display: flex;
      align-items: center;
      gap: 10px;
      color: var(--text-main);
      text-decoration: none;
    }
    .logo-badge {
      background: linear-gradient(135deg, var(--accent-purple), var(--accent-pink));
      width: 32px; height: 32px;
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: 800;
      font-size: 16px;
      color: #fff;
    }
    .nav-links { display: flex; gap: 20px; align-items: center; }
    .nav-links a {
      color: var(--text-muted);
      text-decoration: none;
      font-size: 14px;
      font-weight: 500;
      transition: color 0.2s;
    }
    .nav-links a:hover { color: var(--text-main); }
    .btn-outline {
      padding: 8px 18px;
      border: 1px solid var(--card-border);
      background: rgba(255, 255, 255, 0.05);
      border-radius: 999px;
      color: var(--text-main) !important;
      font-weight: 600;
    }
    .hero {
      max-width: 900px;
      margin: 60px auto 40px;
      text-align: center;
      padding: 0 20px;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      background: rgba(139, 92, 246, 0.12);
      border: 1px solid rgba(139, 92, 246, 0.3);
      padding: 6px 16px;
      border-radius: 999px;
      font-size: 13px;
      font-weight: 600;
      color: #c084fc;
      margin-bottom: 24px;
    }
    .hero h1 {
      font-size: clamp(34px, 5vw, 56px);
      font-weight: 800;
      line-height: 1.15;
      margin-bottom: 20px;
      letter-spacing: -0.02em;
    }
    .hero h1 span {
      background: linear-gradient(135deg, #a78bfa, #f472b6, #60a5fa);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .hero p {
      font-size: clamp(16px, 2vw, 19px);
      color: var(--text-muted);
      max-width: 680px;
      margin: 0 auto 36px;
    }
    .features-grid {
      max-width: 1140px;
      margin: 60px auto;
      padding: 0 20px;
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 24px;
    }
    .feature-card {
      background: var(--card-bg);
      backdrop-filter: blur(12px);
      border: 1px solid var(--card-border);
      border-radius: 20px;
      padding: 32px 28px;
      transition: transform 0.2s, border-color 0.2s;
    }
    .feature-card:hover {
      transform: translateY(-4px);
      border-color: rgba(139, 92, 246, 0.4);
    }
    .feature-icon {
      width: 48px; height: 48px;
      border-radius: 12px;
      background: linear-gradient(135deg, rgba(139, 92, 246, 0.25), rgba(236, 72, 153, 0.25));
      border: 1px solid rgba(139, 92, 246, 0.3);
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 22px;
      margin-bottom: 20px;
    }
    .feature-card h3 {
      font-size: 20px;
      font-weight: 700;
      margin-bottom: 10px;
    }
    .feature-card p {
      font-size: 14px;
      color: var(--text-muted);
      line-height: 1.6;
    }
    .verification-box {
      max-width: 900px;
      margin: 20px auto 60px;
      padding: 28px;
      background: rgba(16, 185, 129, 0.08);
      border: 1px solid rgba(16, 185, 129, 0.25);
      border-radius: 16px;
      text-align: center;
    }
    .verification-box h4 {
      color: #34d399;
      font-size: 16px;
      font-weight: 700;
      margin-bottom: 8px;
    }
    .verification-box p {
      color: #cbd5e1;
      font-size: 14px;
    }
    footer {
      border-top: 1px solid var(--card-border);
      padding: 40px 20px;
      text-align: center;
      color: var(--text-muted);
      font-size: 13px;
      background: rgba(11, 15, 25, 0.95);
    }
    footer .legal-links {
      display: flex;
      justify-content: center;
      gap: 24px;
      margin-bottom: 16px;
      flex-wrap: wrap;
    }
    footer .legal-links a {
      color: #cbd5e1;
      text-decoration: none;
      transition: color 0.2s;
    }
    footer .legal-links a:hover { color: #a78bfa; }
    .badge-msme {
      display: inline-block;
      margin-top: 12px;
      font-size: 12px;
      color: #94a3b8;
    }
  </style>
</head>
<body>
  <div class="gradient-mesh"></div>
  <nav>
    <a href="/" class="logo">
      <div class="logo-badge">⚡</div>
      <span>InstaAuto</span>
    </a>
    <div class="nav-links">
      <a href="/privacy">Privacy Policy</a>
      <a href="/terms">Terms</a>
      <a href="/data-deletion">Data Deletion</a>
      <a href="mailto:nandakumarmadugula@gmail.com" class="btn-outline">Contact Us</a>
    </div>
  </nav>

  <main>
    <section class="hero">
      <div class="pill">⚡ Official Meta Graph API Integration</div>
      <h1>Automate Instagram Engagement with <span>Precision & Trust</span></h1>
      <p>InstaAuto Technologies provides compliant, automated comment responses and direct messaging tools designed for modern creators, digital entrepreneurs, and growing businesses.</p>
    </section>

    <div class="verification-box">
      <h4>🏛️ Registered Micro-Enterprise (Govt. of India)</h4>
      <p><strong>Enterprise Name:</strong> INSTAAUTO TECHNOLOGIES &bull; <strong>MSME Udyam:</strong> UDYAM-AP-17-0089286 &bull; <strong>Activity:</strong> Computer Programming & Software Services (NIC 62011)</p>
    </div>

    <section class="features-grid">
      <div class="feature-card">
        <div class="feature-icon">💬</div>
        <h3>Instant Comment Auto-Reply</h3>
        <p>Detect keyword triggers on reels and posts in real time. Deliver relevant, personalized responses to boost reach and engagement instantly.</p>
      </div>

      <div class="feature-card">
        <div class="feature-icon">📩</div>
        <h3>Compliant Private Messaging</h3>
        <p>Send direct messages triggered by comments in full adherence with Meta's 7-day conversation window and anti-spam rate limiting.</p>
      </div>

      <div class="feature-card">
        <div class="feature-icon">🛡️</div>
        <h3>Meta Policy & Security First</h3>
        <p>End-to-end HMAC SHA-256 webhook signature validation, zero unauthorized data retention, and instant user data deletion compliance.</p>
      </div>
    </section>
  </main>

  <footer>
    <div class="legal-links">
      <a href="/privacy">Privacy Policy</a>
      <a href="/terms">Terms of Service</a>
      <a href="/data-deletion">User Data Deletion</a>
      <a href="/health">System Status</a>
    </div>
    <p>&copy; 2026 INSTAAUTO TECHNOLOGIES. All rights reserved.</p>
    <p class="badge-msme">Peddapuram, Kakinada District, Andhra Pradesh 533437, India &bull; Contact: nandakumarmadugula@gmail.com</p>
  </footer>
</body>
</html>`);
  });
}

// SPA Fallback for Flutter Web routes
app.get("{*path}", (req, res, next) => {
  if (fs.existsSync(path.join(webBuildPath, "index.html"))) {
    const reserved = ["/api", "/auth", "/webhook", "/status", "/health", "/test-comment", "/verify-token", "/download-apk", "/privacy", "/terms", "/data-deletion", "/data-deletion-callback", "/deauthorize", "/meta-review-info"];
    if (reserved.some((prefix) => req.url.startsWith(prefix))) {
      return next();
    }
    res.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
    return res.sendFile(path.join(webBuildPath, "index.html"));
  }
  next();
});

// ── Start Server ──────────────────────────────────────────────────────────────
app.listen(PORT, async () => {
  console.log("════════════════════════════════════════════════════════════════");
  console.log(`🚀 InstaAuto Server running on port ${PORT}`);
  console.log(`   Mode       : ${process.env.DRY_RUN === "false" ? "LIVE" : "DRY_RUN"}`);
  console.log(`   Webhook    : /webhook (Meta HMAC Verification Active)`);
  console.log(`   Compliance : 7-Day Window | 1 DM/Comment | Anti-Spam Jitter`);
  console.log("════════════════════════════════════════════════════════════════");

  const token = process.env.INSTAGRAM_ACCESS_TOKEN;
  if (token && token.length > 10) {
    try {
      // Auto subscribe webhook fields on Meta
      await fetch(
        `${GRAPH_API_BASE}/me/subscribed_apps?subscribed_fields=comments,messages&access_token=${token}`,
        { method: "POST" }
      );
      console.log("🔔 [Meta] Webhook fields subscribed ✅");
    } catch (_) {}
  }
});
