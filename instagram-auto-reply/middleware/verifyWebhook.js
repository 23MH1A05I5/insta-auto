// ════════════════════════════════════════════════════════════════════════════
// Meta Webhook Signature Verification Middleware
// Instagram Platform Rule: Meta requires apps to verify X-Hub-Signature-256
// ════════════════════════════════════════════════════════════════════════════
const crypto = require("crypto");

/**
 * Middleware to verify that incoming webhook payloads genuinely originate from Meta.
 * Compares X-Hub-Signature-256 with HMAC-SHA256(rawBody, INSTAGRAM_APP_SECRET).
 * Enforces fail-closed security in production.
 */
function verifyMetaWebhookSignature(req, res, next) {
  const signature = req.headers["x-hub-signature-256"];
  const appSecret = process.env.INSTAGRAM_APP_SECRET;
  const isProduction = process.env.NODE_ENV === "production";

  // 1. Production Fail-Closed Security: Must have secret configured
  if (isProduction) {
    if (!appSecret || appSecret.trim() === "" || appSecret.includes("YOUR_META_APP_SECRET")) {
      console.error("🚨 [Security Alert] INSTAGRAM_APP_SECRET is unconfigured or a placeholder in production! Request rejected.");
      return res.status(500).send("Webhook secret configuration error");
    }

    if (!signature) {
      console.warn("🔒 [Security] Missing X-Hub-Signature-256 header in production webhook request.");
      return res.status(401).send("Missing signature");
    }
  } else {
    // Development or local test mode:
    if (!signature) {
      return next();
    }
    if (!appSecret || appSecret.includes("YOUR_META_APP_SECRET")) {
      console.warn("⚠️ [Security] INSTAGRAM_APP_SECRET is not configured. Webhook signature skipped in development.");
      return next();
    }
  }

  // 2. Validate HMAC Signature using exact raw request body
  try {
    const rawBody = req.rawBody || (req.body ? JSON.stringify(req.body) : "");
    const expectedSignature = `sha256=${crypto
      .createHmac("sha256", appSecret)
      .update(rawBody)
      .digest("hex")}`;

    const sigBuffer = Buffer.from(signature, "utf8");
    const expectedBuffer = Buffer.from(expectedSignature, "utf8");

    // Timing-safe comparison to prevent timing side-channel attacks
    if (sigBuffer.length !== expectedBuffer.length || !crypto.timingSafeEqual(sigBuffer, expectedBuffer)) {
      console.error("❌ [Security] Webhook signature mismatch! Possible spoofed request rejected.");
      return res.status(403).send("Invalid signature");
    }

    console.log("🔒 [Security] Meta X-Hub-Signature-256 verified successfully ✅");
    next();
  } catch (err) {
    console.error("❌ [Security] Signature verification error:", err.message);
    return res.status(403).send("Signature verification failed");
  }
}

module.exports = { verifyMetaWebhookSignature };
