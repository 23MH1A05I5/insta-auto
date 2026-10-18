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
  enabled    : { type: Boolean, default: true },
  message    : { type: String, default: "" },
  buttonText : { type: String, default: "Send me the link" },
  link       : { type: String, default: "" },
}, { _id: false });

// ── Activity Log Entry ────────────────────────────────────────────────────────
const activityEntrySchema = new mongoose.Schema({
  commentId    : String,
  username     : String,
  text         : String,
  ruleMatched  : String,
  publicReply  : {
    sent    : Boolean,
    status  : String,
    message : String,
  },
  privateReply : {
    sent    : Boolean,
    status  : String,
    message : String,
    link    : String,
  },
  timestamp    : { type: Date, default: Date.now },
  isDuplicate  : { type: Boolean, default: false },
  error        : { type: String, default: null },
}, { _id: false });

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
    commentsReceived : { type: Number, default: 0 },
    repliesSent      : { type: Number, default: 0 },
    dmsSent          : { type: Number, default: 0 },
    failed           : { type: Number, default: 0 },
  },

  activityLog : { type: [activityEntrySchema], default: [] },
}, { timestamps: true });

// Compound index: one automation per (user × media post)
automationSchema.index({ userId: 1, mediaId: 1 });

module.exports = mongoose.model("Automation", automationSchema);
