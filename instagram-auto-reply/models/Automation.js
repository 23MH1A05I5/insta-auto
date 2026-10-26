const mongoose = require("mongoose");

// ── Keyword Rule Schema ──────────────────────────────────────────────────────
const ruleSchema = new mongoose.Schema({
  matchType  : { type: String, enum: ["keywords", "any"], default: "keywords" },
  keywords   : [{ type: String, trim: true }],   // lowercase normalized
  wholeWord  : { type: Boolean, default: false },
}, { _id: false });

// ── Public Reply Schema ──────────────────────────────────────────────────────
const publicReplySchema = new mongoose.Schema({
  enabled  : { type: Boolean, default: true },
  messages : [{ type: String }],   // random variation picked at send time
}, { _id: false });

// ── DM Schema ────────────────────────────────────────────────────────────────
const dmSchema = new mongoose.Schema({
  enabled      : { type: Boolean, default: true },
  message      : { type: String, default: "" },
  buttonEnabled: { type: Boolean, default: true },
  buttonText   : { type: String, default: "Send me the link" },
  link         : { type: String, default: "" },
}, { _id: false });

// ── Activity Log Entry ────────────────────────────────────────────────────────
const activityEntrySchema = new mongoose.Schema({
  _id          : { type: mongoose.Schema.Types.ObjectId, default: () => new mongoose.Types.ObjectId() },
  commentId    : { type: String, required: true },
  commentTimestamp: { type: Date, default: null },
  username     : String,
  text         : String,
  ruleMatched  : String,
  publicReply  : {
    sent         : { type: Boolean, default: false },
    status       : { 
      type: String, 
      set: (v) => (["api_error", "error", "network_error", "rate_limited"].includes(v) ? "failed" : v),
      enum: [
        "pending", "processing", "sent", "failed", "skipped", "disabled", "unknown",
        "api_error", "error", "rate_limited", "network_error", "expired"
      ],
      default: "disabled" 
    },
    message      : { type: String, default: "" },
    messageId    : { type: String, default: null },
    error        : { type: String, default: null },
    errorCategory: { type: String, default: null },
    errorCode    : { type: Number, default: null },
    errorSubcode : { type: Number, default: null },
    attempts     : { type: Number, default: 0 },
    lastAttemptAt: { type: Date, default: null },
    firstFailedAt: { type: Date, default: null },
    lastFailedAt : { type: Date, default: null },
    lastSuccessAt: { type: Date, default: null },
    skipReason   : { type: String, default: null },
  },
  privateReply : {
    sent            : { type: Boolean, default: false },
    status          : { 
      type: String, 
      set: (v) => (["api_error", "error", "network_error", "rate_limited"].includes(v) ? "failed" : v),
      enum: [
        "pending", "processing", "sent", "failed", "skipped", "disabled", "unknown",
        "api_error", "error", "rate_limited", "network_error", "expired"
      ],
      default: "disabled" 
    },
    message         : { type: String, default: "" },
    link            : { type: String, default: "" },
    buttonText      : { type: String, default: "" },
    messageId       : { type: String, default: null },
    error           : { type: String, default: null },
    errorCategory   : { type: String, default: null },
    errorCode       : { type: Number, default: null },
    errorSubcode    : { type: Number, default: null },
    attempts        : { type: Number, default: 0 },
    lastAttemptAt   : { type: Date, default: null },
    firstFailedAt   : { type: Date, default: null },
    lastFailedAt    : { type: Date, default: null },
    lastSuccessAt   : { type: Date, default: null },
    skipReason      : { type: String, default: null },
    retryEligible   : { type: Boolean, default: false },
    retryReason     : { type: String, default: null },
    isProcessing    : { type: Boolean, default: false },
    processingLockAt: { type: Date, default: null },
  },
  timestamp    : { type: Date, default: Date.now },
  isDuplicate  : { type: Boolean, default: false },
  source       : { type: String, enum: ["webhook", "backfill", "retry"], default: "webhook" },
  error        : { type: String, default: null },
});

// ── Main Automation Schema ────────────────────────────────────────────────────
const automationSchema = new mongoose.Schema({
  userId          : { type: mongoose.Schema.Types.ObjectId, ref: "User", required: true, index: true },
  igUserId        : { type: String, required: true },          // owner IG account ID
  mediaId         : { type: String, required: true },          // target post/reel
  mediaType       : { type: String, enum: ["IMAGE", "VIDEO", "CAROUSEL_ALBUM"], default: "IMAGE" },
  mediaThumbnail  : { type: String, default: null },
  mediaCaption    : { type: String, default: "" },
  mediaTimestamp  : { type: String, default: null },

  name            : { type: String, default: "" },
  status          : { type: String, enum: ["active", "paused", "draft"], default: "draft" },

  trigger         : { type: ruleSchema, default: () => ({}) },
  publicReply     : { type: publicReplySchema, default: () => ({}) },
  openingDm       : { type: dmSchema, default: () => ({}) },
  finalDm         : { type: dmSchema, default: () => ({}) },

  stats : {
    commentsReceived   : { type: Number, default: 0 },
    repliesSent        : { type: Number, default: 0 },
    dmsSent            : { type: Number, default: 0 },
    failed             : { type: Number, default: 0 }, // Outstanding failed actions
    totalFailedAttempts: { type: Number, default: 0 }, // Historical failed attempts
  },

  activityLog : { type: [activityEntrySchema], default: [] },
}, { timestamps: true });

// Compound index: one automation per (user × media post)
automationSchema.index({ userId: 1, mediaId: 1 });
automationSchema.index({ "activityLog.commentId": 1 });
automationSchema.index({ "activityLog._id": 1 });

module.exports = mongoose.model("Automation", automationSchema);
