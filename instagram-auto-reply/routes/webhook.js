// ════════════════════════════════════════════════════════════════════════════
// Meta / Instagram Webhook Routes
// Compliant with Meta Webhook Specifications & Verification Requirements
// ════════════════════════════════════════════════════════════════════════════
const router = require("express").Router();
const { verifyMetaWebhookSignature } = require("../middleware/verifyWebhook");
const AutomationEngine = require("../services/automationEngine");
const Automation = require("../models/Automation");

const VERIFY_TOKEN = process.env.VERIFY_TOKEN || "my_verify_token";

// In-memory rate limiter for test endpoint (max 10 requests/min per IP)
const testEndpointRateLimits = new Map();

// ── GET /webhook — Meta Webhook Handshake Verification ─────────────────────────
router.get("/", (req, res) => {
  const mode = req.query["hub.mode"];
  const token = req.query["hub.verify_token"];
  const challenge = req.query["hub.challenge"];

  if (mode === "subscribe" && token === VERIFY_TOKEN) {
    console.log("✅ [Meta Webhook Handshake] Verified successfully");
    return res.status(200).send(challenge);
  }

  console.warn("❌ [Meta Webhook Handshake] Verification failed: Token mismatch or invalid mode.");
  return res.sendStatus(403);
});

// ── POST /webhook — Receive Instagram Realtime Events ──────────────────────────
// Protected by Meta X-Hub-Signature-256 validation middleware
router.post("/", verifyMetaWebhookSignature, (req, res) => {
  // Instagram Rule: Must return HTTP 200 promptly within 5 seconds to prevent Meta retries
  res.sendStatus(200);

  const body = req.body;
  console.log(`\n📩 [Meta Webhook Event] Object="${body?.object}"`);

  if (!body || (body.object !== "instagram" && body.object !== "page")) {
    return;
  }

  // Process entries asynchronously in the background
  processWebhookEntries(body.entry || []).catch((err) => {
    console.error("❌ [Webhook Processing Error]:", err.message);
  });
});

async function processWebhookEntries(entries) {
  for (const entry of entries) {
    for (const change of entry.changes || []) {
      if (change.field === "comments") {
        await AutomationEngine.handleIncomingComment(change.value);
      } else {
        console.log(`ℹ️ [Webhook] Unhandled field event: ${change.field}`);
      }
    }
  }
}

// ── POST /webhook/test-comment — Protected simulation for diagnostic testing ──
// Requirements:
// 1. Disabled in production unless authenticated by valid ADMIN_API_KEY
// 2. Strict request validation
// 3. In-memory rate limiting
// 4. Server-enforced test mode (simulation only, NEVER real DMs)
router.post("/test-comment", async (req, res) => {
  const isProduction = process.env.NODE_ENV === "production";
  const adminKey = req.headers["x-admin-key"];
  const configuredAdminKey = process.env.ADMIN_API_KEY;

  // 1. Production Protection: Disabled by default, requires admin authentication
  if (isProduction) {
    if (!configuredAdminKey || adminKey !== configuredAdminKey) {
      console.warn("🔒 [Security Alert] Unauthorized access attempt to /webhook/test-comment in production.");
      return res.status(403).json({
        ok: false,
        error: "Test endpoints are disabled in production environment.",
      });
    }
  }

  // 2. Rate Limiting (10 requests per minute per IP)
  const clientIp = req.ip || req.connection?.remoteAddress || "unknown";
  const now = Date.now();
  const clientWindow = testEndpointRateLimits.get(clientIp) || [];
  const recentCalls = clientWindow.filter((ts) => now - ts < 60000);

  if (recentCalls.length >= 10) {
    return res.status(429).json({
      ok: false,
      error: "Rate limit exceeded for test-comment endpoint. Max 10 requests per minute.",
    });
  }
  recentCalls.push(now);
  testEndpointRateLimits.set(clientIp, recentCalls);

  // 3. Input Validation
  const { comment_id, username, text, media_id } = req.body || {};
  if (!comment_id || !username || !text) {
    return res.status(400).json({
      ok: false,
      error: "Missing required fields: comment_id, username, text",
    });
  }

  if (typeof comment_id !== "string" || typeof username !== "string" || typeof text !== "string") {
    return res.status(400).json({
      ok: false,
      error: "Invalid field types: comment_id, username, and text must be strings",
    });
  }

  console.log(`\n🧪 [Simulated Comment Test] ID:${comment_id} @${username}: "${text}"`);

  const mockValue = {
    id: String(comment_id).trim(),
    text: String(text).trim(),
    from: { username: String(username).trim(), id: `sim_user_${Date.now()}` },
    media: { id: media_id ? String(media_id).trim() : "test_media_123" },
    timestamp: new Date().toISOString(),
  };

  // 4. Server-enforced simulation mode: ensure real Instagram API is NEVER invoked
  const originalDryRun = process.env.DRY_RUN;
  process.env.DRY_RUN = "true"; // Force simulation mode on server
  try {
    await AutomationEngine.handleIncomingComment(mockValue);
    return res.json({
      ok: true,
      simulated: true,
      message: "Comment simulation completed safely in test mode",
      comment: mockValue,
    });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  } finally {
    process.env.DRY_RUN = originalDryRun;
  }
});

module.exports = router;
