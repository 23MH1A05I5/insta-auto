// ════════════════════════════════════════════════════════════════════════════
// Meta / Instagram Webhook Routes
// Compliant with Meta Webhook Specifications & Verification Requirements
// ════════════════════════════════════════════════════════════════════════════
const router = require("express").Router();
const { verifyMetaWebhookSignature } = require("../middleware/verifyWebhook");
const AutomationEngine = require("../services/automationEngine");

const VERIFY_TOKEN = process.env.VERIFY_TOKEN || "my_verify_token";

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
  // Instagram Rule: Must return HTTP 200 within 5 seconds to prevent retries
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

// ── POST /webhook/test-comment — Safe simulation for testing ─────────────────
router.post("/test-comment", async (req, res) => {
  const { comment_id, username, text, media_id } = req.body || {};
  if (!comment_id || !username || !text) {
    return res.status(400).json({
      ok: false,
      error: "Missing required fields: comment_id, username, text",
    });
  }

  console.log(`\n🧪 [Simulated Comment Test] ID:${comment_id} @${username}: "${text}"`);

  const mockValue = {
    id: comment_id,
    text,
    from: { username, id: `test_user_${Date.now()}` },
    media: { id: media_id || "test_media_123" },
    timestamp: new Date().toISOString(),
  };

  try {
    await AutomationEngine.handleIncomingComment(mockValue);
    return res.json({ ok: true, message: "Comment simulation completed", comment: mockValue });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

module.exports = router;
