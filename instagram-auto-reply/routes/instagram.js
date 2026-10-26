const router = require("express").Router();
const crypto = require("crypto");
const User = require("../models/User");
const ActionLedger = require("../models/ActionLedger");
const Automation = require("../models/Automation");
const { authenticate } = require("../middleware/auth");
const InstagramService = require("../services/instagramService");
const AiReplyService = require("../services/aiReplyService");

const IG_APP_ID = process.env.INSTAGRAM_APP_ID || "";
const IG_APP_SECRET = process.env.INSTAGRAM_APP_SECRET || "";
const IG_REDIRECT_URI = process.env.INSTAGRAM_REDIRECT_URI || "http://localhost:3000/auth/instagram/callback";
const FRONTEND_DEEP = process.env.FRONTEND_DEEP_LINK || "instauto://oauth-callback";

// In-memory CSRF state store
const oauthStates = new Map();

function storeState(state, userId) {
  oauthStates.set(state, { userId, expiresAt: Date.now() + 10 * 60 * 1000 });
}

function consumeState(state) {
  const entry = oauthStates.get(state);
  oauthStates.delete(state);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) return null;
  return entry;
}

// Prune expired states periodically
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of oauthStates) {
    if (now > v.expiresAt) oauthStates.delete(k);
  }
}, 5 * 60 * 1000);

// ── POST /api/instagram/oauth/start ─────────────────────────────────────────
router.post("/oauth/start", authenticate, (req, res) => {
  if (!IG_APP_ID) {
    return res.status(503).json({ ok: false, error: "INSTAGRAM_APP_ID not configured on server" });
  }
  const state = crypto.randomBytes(24).toString("hex");
  storeState(state, req.user._id.toString());

  const scopes = [
    "instagram_business_basic",
    "instagram_business_manage_comments",
    "instagram_business_manage_messages",
  ].join(",");

  const url = `https://www.instagram.com/oauth/authorize?client_id=${IG_APP_ID}&redirect_uri=${encodeURIComponent(
    IG_REDIRECT_URI
  )}&scope=${scopes}&response_type=code&state=${state}&enable_fb_login=0`;
  return res.json({ ok: true, url, state });
});

// ── GET /auth/instagram/callback ─────────────────────────────────────────────
router.get("/instagram/callback", async (req, res) => {
  const { code, state, error: igError, error_description } = req.query;
  const sendHTML = (statusCode, html) =>
    res
      .status(statusCode)
      .send(
        `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>InstaAuto</title></head><body style="margin:0;background:#f5f5f5;">${html}</body></html>`
      );

  if (igError) {
    console.error("[IG OAuth] Error from Meta:", igError, error_description);
    return sendHTML(
      400,
      `
      <div style="font-family:sans-serif;max-width:500px;margin:60px auto;padding:30px;border-radius:16px;background:#fff;box-shadow:0 4px 20px rgba(0,0,0,0.1);text-align:center;">
        <h2 style="color:#ef4444;">❌ Authorization Cancelled</h2>
        <p style="color:#666;">${error_description || igError}</p>
        <p style="color:#999;font-size:13px;margin-top:20px;">You can close this window and try again from the app.</p>
      </div>
    `
    );
  }

  if (!code) {
    return sendHTML(
      200,
      `
      <div style="font-family:sans-serif;max-width:500px;margin:60px auto;padding:30px;border-radius:16px;background:#fff;box-shadow:0 4px 20px rgba(0,0,0,0.1);text-align:center;">
        <h2 style="color:#7c3aed;margin:0 0 10px;">InstaAuto OAuth Endpoint</h2>
        <p style="color:#666;font-size:14px;line-height:1.5;">This endpoint is active and ready for Meta Instagram authorization callbacks.</p>
      </div>
    `
    );
  }

  let targetUserId = null;
  if (state) {
    const entry = consumeState(state);
    if (entry) targetUserId = entry.userId;
  }
  if (!targetUserId) {
    const latestUser = await User.findOne().sort({ createdAt: -1 });
    if (latestUser) targetUserId = latestUser._id;
  }

  try {
    if (!IG_APP_SECRET || IG_APP_SECRET === "YOUR_META_APP_SECRET_HERE") {
      throw new Error("INSTAGRAM_APP_SECRET is not set in .env. Please copy your App Secret from Meta Developer Dashboard.");
    }

    const cleanCode = (code || "").toString().replace(/#_.*$/, "");

    // Exchange code → short-lived token
    const tokenRes = await fetch("https://api.instagram.com/oauth/access_token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: IG_APP_ID,
        client_secret: IG_APP_SECRET,
        grant_type: "authorization_code",
        redirect_uri: IG_REDIRECT_URI,
        code: cleanCode,
      }),
    });
    const tokenData = await tokenRes.json();
    if (tokenData.error_type || !tokenData.access_token) {
      throw new Error(tokenData.error_message || "Token exchange failed");
    }

    // Exchange short-lived → long-lived token (60-day Meta token)
    const llRes = await fetch(
      `https://graph.instagram.com/access_token?grant_type=ig_exchange_token&client_secret=${IG_APP_SECRET}&access_token=${tokenData.access_token}`
    );
    const llData = await llRes.json();
    const finalToken = llData.access_token || tokenData.access_token;
    const expiresIn = llData.expires_in || 5183944; // ~60 days

    // Fetch account info
    let meData = null;
    const fieldsToTry = ["id,username,account_type", "id,username,name", "id,username"];

    for (const fields of fieldsToTry) {
      try {
        const meRes = await fetch(`https://graph.instagram.com/v21.0/me?fields=${fields}&access_token=${finalToken}`);
        const data = await meRes.json();
        if (data.id) {
          meData = data;
          break;
        }
      } catch (e) {
        console.warn(`[IG OAuth] /me error with fields="${fields}":`, e.message);
      }
    }

    if (!meData?.id) {
      try {
        const meRes = await fetch(`https://graph.instagram.com/me?fields=id,username&access_token=${finalToken}`);
        const data = await meRes.json();
        if (data.id) meData = data;
      } catch (_) {}
    }

    if (!meData?.id) {
      throw new Error(
        "Could not access Instagram profile for this account. Ensure the account is an Instagram Tester or in Live mode."
      );
    }

    // Subscribe to webhook events
    try {
      await fetch(
        `https://graph.instagram.com/v21.0/me/subscribed_apps?subscribed_fields=comments,messages&access_token=${finalToken}`,
        { method: "POST" }
      );
    } catch (_) {}

    // Save to user record
    if (targetUserId) {
      await User.findByIdAndUpdate(targetUserId, {
        "instagram.userId": meData.id,
        "instagram.username": meData.username,
        "instagram.accountType": meData.account_type || "PROFESSIONAL",
        "instagram.accessToken": finalToken,
        "instagram.tokenExpiry": new Date(Date.now() + expiresIn * 1000),
        "instagram.connectedAt": new Date(),
      });
    }

    console.log(`✅ [IG OAuth] Connected @${meData.username} (Account ID: ${meData.id})`);

    const deepLink = `${FRONTEND_DEEP}?success=1&username=${encodeURIComponent(meData.username)}`;
    return sendHTML(
      200,
      `
      <div style="font-family:sans-serif;max-width:500px;margin:60px auto;padding:30px;border-radius:16px;background:#fff;box-shadow:0 4px 20px rgba(0,0,0,0.1);text-align:center;">
        <div style="width:60px;height:60px;background:#10b981;border-radius:50%;margin:0 auto 16px;display:flex;align-items:center;justify-content:center;color:#fff;font-size:32px;">✓</div>
        <h2 style="color:#111;margin:0 0 8px;">Instagram Connected!</h2>
        <p style="color:#7c3aed;font-size:18px;font-weight:bold;margin:0 0 16px;">@${meData.username}</p>
        <p style="color:#666;font-size:14px;line-height:1.5;">Your professional Instagram account is now linked to InstaAuto.<br/>Webhooks for comments and DMs are activated.</p>
        <div style="margin-top:20px;display:flex;gap:12px;justify-content:center;flex-wrap:wrap;">
          <button onclick="window.close()" style="background:#10b981;color:#fff;border:none;padding:12px 24px;border-radius:8px;font-weight:600;font-size:14px;cursor:pointer;">✓ Done (Close Tab)</button>
          <a id="open-app-btn" href="${deepLink}" style="background:#7c3aed;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:600;font-size:14px;display:inline-block;">Open Mobile App</a>
        </div>
        <p style="color:#888;font-size:13px;margin-top:20px;">You can now safely close this tab and return to the InstaAuto app tab.</p>
      </div>
      <script>
        setTimeout(function() {
          try { window.location.href = "${deepLink}"; } catch(e) {}
        }, 800);
      </script>
    `
    );
  } catch (err) {
    console.error("[IG OAuth] Callback error:", err.message);
    return sendHTML(
      500,
      `
      <div style="font-family:sans-serif;max-width:520px;margin:50px auto;padding:28px;border-radius:16px;background:#fff;box-shadow:0 4px 20px rgba(0,0,0,0.1);text-align:center;">
        <h2 style="color:#ef4444;margin:0 0 10px;">Connection Error</h2>
        <p style="color:#666;font-size:14px;line-height:1.5;">${err.message}</p>
        <button onclick="window.close()" style="background:#7c3aed;color:#fff;border:none;padding:10px 20px;border-radius:8px;font-weight:600;font-size:14px;cursor:pointer;margin-top:10px;">Close Window</button>
      </div>
    `
    );
  }
});

// ── GET /api/instagram/status ─────────────────────────────────────────────────
router.get("/status", authenticate, (req, res) => {
  const ig = req.user.instagram;
  if (!ig?.userId) {
    return res.json({ ok: true, connected: false });
  }
  return res.json({
    ok: true,
    connected: true,
    userId: ig.userId,
    username: ig.username,
    accountType: ig.accountType,
    connectedAt: ig.connectedAt,
    tokenExpiry: ig.tokenExpiry,
  });
});

// ── GET /api/instagram/media ─────────────────────────────────────────────────
router.get("/media", authenticate, async (req, res) => {
  const token = req.user.instagram?.accessToken;
  if (!token) {
    return res.status(400).json({ ok: false, error: "No Instagram account connected" });
  }

  const result = await InstagramService.fetchMedia(token, req.query.limit, req.query.cursor);
  if (!result.ok) {
    const msg = result.error?.message || (typeof result.error === "string" ? result.error : "Failed to fetch media");
    return res.status(400).json({ ok: false, error: msg, details: result.error });
  }
  return res.json(result);
});

// ── DELETE /api/instagram/disconnect ─────────────────────────────────────────
router.delete("/disconnect", authenticate, async (req, res) => {
  await User.findByIdAndUpdate(req.user._id, {
    "instagram.userId": null,
    "instagram.username": null,
    "instagram.accountType": null,
    "instagram.accessToken": null,
    "instagram.tokenExpiry": null,
    "instagram.connectedAt": null,
  });
  return res.json({ ok: true, message: "Instagram account disconnected" });
});

// ── GET /api/instagram/media/:mediaId/comments ────────────────────────────────
router.get("/media/:mediaId/comments", authenticate, async (req, res) => {
  const token = req.user.instagram?.accessToken;
  if (!token) {
    return res.status(400).json({ ok: false, error: "No Instagram account connected" });
  }

  const result = await InstagramService.fetchComments(
    req.params.mediaId,
    token,
    req.query.limit,
    req.query.cursor
  );

  if (!result.ok) {
    const msg = result.error?.message || (typeof result.error === "string" ? result.error : "Failed to fetch comments");
    return res.status(400).json({ ok: false, error: msg, details: result.error });
  }

  // Enrich comments with action ledger & automation activity statuses
  try {
    const rawComments = Array.isArray(result.comments) ? result.comments : [];
    const commentIds = rawComments.map((c) => c.id).filter(Boolean);

    if (commentIds.length > 0) {
      const [ledgers, userAutomations] = await Promise.all([
        ActionLedger.find({ commentId: { $in: commentIds } }).lean().catch(() => []),
        Automation.find({ userId: req.user._id, mediaId: req.params.mediaId })
          .select("activityLog openingDm publicReply")
          .lean()
          .catch(() => []),
      ]);

      const now = Date.now();
      const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

      result.comments = rawComments.map((c) => {
        const commentObj = { ...c };
        const dmLedger = ledgers.find((l) => l.commentId === c.id && l.actionType === "dm");
        const pubLedger = ledgers.find((l) => l.commentId === c.id && l.actionType === "public_reply");

        // Find in automation activityLog
        let actEntry = null;
        for (const auto of userAutomations) {
          const found = (auto.activityLog || []).find((log) => log.commentId === c.id);
          if (found) {
            actEntry = found;
            break;
          }
        }

        const commentTime = c.timestamp ? new Date(c.timestamp).getTime() : null;
        const isOlderThan7Days = commentTime && !isNaN(commentTime) ? now - commentTime > SEVEN_DAYS_MS : false;

        // Check if DM was already sent
        const dmAlreadySent = dmLedger?.status === "sent" || actEntry?.privateReply?.sent || actEntry?.privateReply?.status === "sent";

        let isEligibleForDm = true;
        let dmIneligibleReason = null;

        if (dmAlreadySent) {
          isEligibleForDm = false;
          dmIneligibleReason = "A private DM has already been sent to this user for this comment.";
        } else if (isOlderThan7Days) {
          isEligibleForDm = false;
          dmIneligibleReason = "Meta messaging policy: Comments older than 7 days cannot receive private DMs.";
        }

        const pubStatus = pubLedger?.status || actEntry?.publicReply?.status || (c.replies?.data?.length > 0 ? "sent" : "none");
        let dmStatus = dmLedger?.status || actEntry?.privateReply?.status || (dmAlreadySent ? "sent" : (isEligibleForDm ? "none" : "ineligible"));

        commentObj.publicReplyStatus = pubStatus;
        commentObj.dmStatus = dmStatus;
        commentObj.isEligibleForDm = isEligibleForDm;
        commentObj.dmIneligibleReason = dmIneligibleReason;

        if (dmLedger) {
          commentObj.actionLedger = {
            ok: true,
            actionId: dmLedger._id?.toString(),
            commentId: dmLedger.commentId,
            mediaId: dmLedger.mediaId,
            actionType: dmLedger.actionType,
            status: dmLedger.status,
            reason: dmLedger.skipReason || dmLedger.error,
            retryable: Boolean(dmLedger.isRetryable),
            messageId: dmLedger.messageId,
            sentAt: dmLedger.sentAt || dmLedger.createdAt,
            reconciliationRequired: Boolean(dmLedger.isAmbiguous),
            updatedAt: dmLedger.updatedAt,
          };
        }

        return commentObj;
      });
    }
  } catch (enrichErr) {
    console.warn("⚠️ [Comment Enrich Warning]:", enrichErr.message);
  }

  return res.json(result);
});

// ── POST /api/instagram/comments/:commentId/reply ────────────────────────────
router.post("/comments/:commentId/reply", authenticate, async (req, res) => {
  const token = req.user.instagram?.accessToken;
  if (!token) {
    return res.status(400).json({ ok: false, error: "No Instagram account connected" });
  }

  const { message } = req.body;
  if (!message || !message.trim()) {
    return res.status(400).json({ ok: false, error: "Message is required" });
  }

  const result = await InstagramService.publishCommentReply(req.params.commentId, message, token);
  if (!result.ok) {
    const msg = result.error?.message || (typeof result.error === "string" ? result.error : "Failed to reply to comment");
    return res.status(400).json({ ok: false, error: msg, details: result.error });
  }
  return res.json(result);
});

// ── POST /api/instagram/users/:igUserId/dm ───────────────────────────────────
router.post("/users/:igUserId/dm", authenticate, async (req, res) => {
  const token = req.user.instagram?.accessToken;
  if (!token) {
    return res.status(400).json({ ok: false, error: "No Instagram account connected" });
  }

  const { message } = req.body;
  if (!message || !message.trim()) {
    return res.status(400).json({ ok: false, error: "Message is required" });
  }

  const result = await InstagramService.sendDirectMessage(req.params.igUserId, message, token);
  if (!result.ok) {
    const msg = result.error?.message || (typeof result.error === "string" ? result.error : "Failed to send DM");
    return res.status(400).json({ ok: false, error: msg, details: result.error });
  }
  return res.json(result);
});

// ── POST /api/instagram/comments/suggest-replies ─────────────────────────────
router.post("/comments/suggest-replies", authenticate, async (req, res) => {
  const { commentText, username } = req.body;
  if (!commentText) {
    return res.status(400).json({ ok: false, error: "commentText is required" });
  }

  const suggestions = AiReplyService.generateSuggestions(commentText, {
    username,
    productName: process.env.PRODUCT_NAME,
    price: process.env.PRODUCT_PRICE,
    currency: process.env.CURRENCY,
    link: process.env.PRODUCT_LINK,
  });

  return res.json({ ok: true, suggestions });
});

// ── GET /api/instagram/media/:mediaId/stats ───────────────────────────────────
router.get("/media/:mediaId/stats", authenticate, async (req, res) => {
  const token = req.user.instagram?.accessToken;
  if (!token) {
    return res.status(400).json({ ok: false, error: "No Instagram account connected" });
  }

  const result = await InstagramService.fetchMediaStats(req.params.mediaId, token);
  if (!result.ok) {
    const msg = result.error?.message || (typeof result.error === "string" ? result.error : "Failed to fetch stats");
    return res.status(400).json({ ok: false, error: msg, details: result.error });
  }
  return res.json(result);
});

module.exports = router;
