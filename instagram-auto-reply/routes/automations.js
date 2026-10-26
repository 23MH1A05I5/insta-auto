const router     = require("express").Router();
const Automation = require("../models/Automation");
const BackfillJob = require("../models/BackfillJob");
const BackfillService = require("../services/backfillService");
const { authenticate } = require("../middleware/auth");

// ── GET /api/automations/backfill/jobs/:jobId ─────────────────────────────────
router.get("/backfill/jobs/:jobId", authenticate, async (req, res) => {
  try {
    const job = await BackfillJob.findOne({ _id: req.params.jobId, userId: req.user._id });
    if (!job) return res.status(404).json({ ok: false, error: "Job not found" });
    return res.json({ ok: true, job });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── POST /api/automations/backfill/jobs/:jobId/retry ──────────────────────────
router.post("/backfill/jobs/:jobId/retry", authenticate, async (req, res) => {
  try {
    const result = await BackfillService.retryJob(req.params.jobId, req.user._id);
    return res.json(result);
  } catch (err) {
    return res.status(400).json({ ok: false, error: err.message, errorCode: err.code || "VALIDATION_ERROR" });
  }
});

// ── POST /api/automations/backfill/jobs/:jobId/resume ─────────────────────────
router.post("/backfill/jobs/:jobId/resume", authenticate, async (req, res) => {
  try {
    const result = await BackfillService.resumeJob(req.params.jobId, req.user._id);
    return res.json(result);
  } catch (err) {
    return res.status(400).json({ ok: false, error: err.message, errorCode: err.code || "VALIDATION_ERROR" });
  }
});

// ── GET /api/automations ──────────────────────────────────────────────────────
router.get("/", authenticate, async (req, res) => {
  try {
    const automations = await Automation.find({ userId: req.user._id })
      .sort({ createdAt: -1 })
      .select("-activityLog");
    return res.json({ ok: true, automations });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── POST /api/automations ─────────────────────────────────────────────────────
router.post("/", authenticate, async (req, res) => {
  try {
    const ig = req.user.instagram;
    if (!ig?.userId) {
      return res.status(400).json({ ok: false, error: "No Instagram account connected" });
    }
    const { mediaId, mediaType, mediaThumbnail, mediaCaption, mediaTimestamp,
            name, trigger, publicReply, openingDm, finalDm, status } = req.body;

    if (!mediaId) return res.status(400).json({ ok: false, error: "mediaId is required" });

    // Check if an automation was already created for this post
    const existing = await Automation.findOne({ userId: req.user._id, mediaId });
    if (existing) {
      return res.status(400).json({
        ok: false,
        error: "An automation was already created for this post. Please edit the existing automation instead.",
      });
    }

    // Normalize trigger keywords to lowercase unique array
    if (trigger?.keywords) {
      trigger.keywords = [...new Set(
        trigger.keywords.map((k) => k.toLowerCase().trim()).filter(Boolean)
      )];
    }

    const automation = await Automation.create({
      userId: req.user._id,
      igUserId: ig.userId,
      mediaId, mediaType, mediaThumbnail, mediaCaption, mediaTimestamp,
      name, trigger, publicReply, openingDm, finalDm,
      status: status || "draft",
    });
    return res.status(201).json({ ok: true, automation });
  } catch (err) {
    console.error("[POST /automations]", err.message);
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── GET /api/automations/:id ──────────────────────────────────────────────────
router.get("/:id", authenticate, async (req, res) => {
  try {
    const automation = await Automation.findOne({ _id: req.params.id, userId: req.user._id });
    if (!automation) return res.status(404).json({ ok: false, error: "Not found" });
    return res.json({ ok: true, automation });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── PUT /api/automations/:id ──────────────────────────────────────────────────
router.put("/:id", authenticate, async (req, res) => {
  try {
    const automation = await Automation.findOne({ _id: req.params.id, userId: req.user._id });
    if (!automation) return res.status(404).json({ ok: false, error: "Not found" });

    const allowed = ["name","trigger","publicReply","openingDm","finalDm",
                     "mediaType","mediaThumbnail","mediaCaption","mediaTimestamp","status"];
    allowed.forEach((field) => {
      if (req.body[field] !== undefined) automation[field] = req.body[field];
    });

    if (automation.trigger?.keywords) {
      automation.trigger.keywords = [...new Set(
        automation.trigger.keywords.map((k) => k.toLowerCase().trim()).filter(Boolean)
      )];
    }
    await automation.save();
    return res.json({ ok: true, automation });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── PATCH /api/automations/:id/status ────────────────────────────────────────
router.patch("/:id/status", authenticate, async (req, res) => {
  try {
    const { status } = req.body;
    if (!["active", "paused", "draft"].includes(status)) {
      return res.status(400).json({ ok: false, error: "status must be active | paused | draft" });
    }
    const automation = await Automation.findOneAndUpdate(
      { _id: req.params.id, userId: req.user._id },
      { status },
      { new: true }
    );
    if (!automation) return res.status(404).json({ ok: false, error: "Not found" });
    return res.json({ ok: true, automation });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── POST /api/automations/:id/backfill/preview ────────────────────────────────
router.post("/:id/backfill/preview", authenticate, async (req, res) => {
  try {
    const preview = await BackfillService.preview(req.user._id, req.params.id, req.body?.mediaId);
    return res.json({ ok: true, ...preview, preview });
  } catch (err) {
    return res.status(400).json({ ok: false, error: err.message, errorCode: err.code || "VALIDATION_ERROR" });
  }
});

// ── POST /api/automations/:id/backfill/start ──────────────────────────────────
router.post("/:id/backfill/start", authenticate, async (req, res) => {
  try {
    const { mediaId, selectedCommentIds } = req.body || {};
    const result = await BackfillService.startJob(req.user._id, req.params.id, mediaId, selectedCommentIds);
    return res.json(result);
  } catch (err) {
    return res.status(400).json({ ok: false, error: err.message, errorCode: err.code || "VALIDATION_ERROR" });
  }
});

// ── GET /api/automations/:id/backfill/latest ──────────────────────────────────
router.get("/:id/backfill/latest", authenticate, async (req, res) => {
  try {
    const job = await BackfillJob.findOne({ automationId: req.params.id, userId: req.user._id }).sort({ createdAt: -1 });
    return res.json({ ok: true, job });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── DELETE /api/automations/:id ───────────────────────────────────────────────
router.delete("/:id", authenticate, async (req, res) => {
  try {
    const automation = await Automation.findOneAndDelete({ _id: req.params.id, userId: req.user._id });
    if (!automation) return res.status(404).json({ ok: false, error: "Not found" });
    return res.json({ ok: true, message: "Automation deleted" });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

module.exports = router;
