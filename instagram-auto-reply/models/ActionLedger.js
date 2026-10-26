const mongoose = require("mongoose");

const actionLedgerSchema = new mongoose.Schema(
  {
    actionKey: {
      type: String,
      required: true,
      unique: true,
      index: true,
    },
    igUserId: {
      type: String,
      required: true,
      index: true,
    },
    mediaId: {
      type: String,
      required: true,
      index: true,
    },
    commentId: {
      type: String,
      required: true,
      index: true,
    },
    recipientId: {
      type: String,
      default: null,
      index: true,
    },
    username: {
      type: String,
      default: "unknown",
      index: true,
    },
    actionType: {
      type: String,
      enum: ["dm", "public_reply"],
      required: true,
      index: true,
    },
    status: {
      type: String,
      enum: [
        "pending",
        "processing",
        "sent",
        "success", // compatibility alias
        "failed",
        "skipped",
        "unknown",
        "reconciliation_required",
        "already_processed", // compatibility alias
        "already_sent", // compatibility alias
      ],
      default: "pending",
      index: true,
    },
    skipReason: {
      type: String,
      default: null,
    },
    claimToken: {
      type: String,
      default: null,
    },
    claimExpiresAt: {
      type: Date,
      default: null,
      index: true,
    },
    attempts: {
      type: Number,
      default: 0,
    },
    messageId: {
      type: String,
      default: null,
    },
    messageText: {
      type: String,
      default: "",
    },
    error: {
      type: String,
      default: null,
    },
    errorCode: {
      type: Number,
      default: null,
    },
    errorCategory: {
      type: String,
      default: null,
    },
    isRetryable: {
      type: Boolean,
      default: true,
    },
    isAmbiguous: {
      type: Boolean,
      default: false,
    },
    reconciledAt: {
      type: Date,
      default: null,
    },
    reconciliationReason: {
      type: String,
      default: null,
    },
    reconciledFrom: {
      type: String,
      default: null,
    },
    automationId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Automation",
      default: null,
      index: true,
    },
    jobId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "BackfillJob",
      default: null,
      index: true,
    },
    source: {
      type: String,
      enum: ["webhook", "backfill", "retry", "reconciliation"],
      default: "webhook",
    },
    lastAttemptAt: {
      type: Date,
      default: null,
    },
    processedAt: {
      type: Date,
      default: null,
    },
  },
  {
    timestamps: true,
  }
);

// Compound indexes to ensure database-level uniqueness & fast lookups
actionLedgerSchema.index(
  { igUserId: 1, mediaId: 1, commentId: 1, actionType: 1 },
  { unique: true, name: "uniq_ig_media_comment_action" }
);

actionLedgerSchema.index(
  { igUserId: 1, mediaId: 1, recipientId: 1, actionType: 1, status: 1 },
  { name: "lookup_recipient_media_action" }
);

actionLedgerSchema.index(
  { status: 1, claimExpiresAt: 1 },
  { name: "lookup_lease_status" }
);

module.exports = mongoose.model("ActionLedger", actionLedgerSchema);
