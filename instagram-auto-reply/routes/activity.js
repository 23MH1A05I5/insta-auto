const router     = require("express").Router();
const Automation = require("../models/Automation");
const { authenticate } = require("../middleware/auth");

// ── GET /api/activity ─────────────────────────────────────────────────────────
router.get("/", authenticate, async (req, res) => {
  try {
    const limit  = Math.min(parseInt(req.query.limit || "50", 10), 200);
    const page   = Math.max(parseInt(req.query.page  || "1",  10), 1);
    const skip   = (page - 1) * limit;

    // Pull activityLog entries from all user automations, flatten and sort
    const automations = await Automation.find({ userId: req.user._id })
      .select("mediaId mediaThumbnail activityLog name");

    const entries = [];
    for (const auto of automations) {
      for (const entry of auto.activityLog) {
        entries.push({
          automationId  : auto._id,
          automationName: auto.name,
          mediaId       : auto.mediaId,
          mediaThumbnail: auto.mediaThumbnail,
          ...entry.toObject(),
        });
      }
    }

    // Sort by timestamp DESC
    entries.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
    const total  = entries.length;
    const paged  = entries.slice(skip, skip + limit);
    return res.json({ ok: true, total, page, limit, activity: paged });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── GET /api/analytics/summary ────────────────────────────────────────────────
router.get("/summary", authenticate, async (req, res) => {
  try {
    const automations = await Automation.find({ userId: req.user._id }).select("stats status");

    const summary = {
      totalAutomations    : automations.length,
      activeAutomations   : automations.filter((a) => a.status === "active").length,
      commentsReceived    : 0,
      repliesSent         : 0,
      dmsSent             : 0,
      failedActions       : 0,
    };

    for (const a of automations) {
      summary.commentsReceived += a.stats.commentsReceived;
      summary.repliesSent      += a.stats.repliesSent;
      summary.dmsSent          += a.stats.dmsSent;
      summary.failedActions    += a.stats.failed;
    }

    return res.json({ ok: true, summary });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

module.exports = router;
