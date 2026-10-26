const mongoose = require("mongoose");

const backfillActionSchema = new mongoose.Schema(
  {
    commentId: { type: String, required: true },
    recipientId: { type: String, default: null },
    username: { type: String, default: "unknown" },
    text: { type: String, default: "" },
    commentTimestamp: { type: Date, default: null },
    ruleMatched: { type: String, default: "no_match" },
    status: {
      type: String,
      enum: [
        "pending",
        "processing",
        "sent",
        "success",
        "failed",
        "skipped",
        "already_processed",
        "already_sent",
        "unknown",
        "reconciliation_required",
      ],
      default: "pending",
    },
    skipReason: { type: String, default: null },
    publicReply: {
      status: {
        type: String,
        enum: [
          "pending",
          "processing",
          "sent",
          "success",
          "failed",
          "skipped",
          "disabled",
          "unknown",
          "reconciliation_required",
        ],
        default: "disabled",
      },
      skipReason: { type: String, default: null },
      message: { type: String, default: "" },
      messageId: { type: String, default: null },
      error: { type: String, default: null },
      errorCode: { type: Number, default: null },
      errorCategory: { type: String, default: null },
      retryEligible: { type: Boolean, default: false },
      retryReason: { type: String, default: null },
      attempts: { type: Number, default: 0 },
      lastAttemptAt: { type: Date, default: null },
    },
    privateReply: {
      status: {
        type: String,
        enum: [
          "pending",
          "processing",
          "sent",
          "success",
          "failed",
          "skipped",
          "disabled",
          "unknown",
          "reconciliation_required",
        ],
        default: "disabled",
      },
      skipReason: { type: String, default: null },
      message: { type: String, default: "" },
      messageId: { type: String, default: null },
      error: { type: String, default: null },
      errorCode: { type: Number, default: null },
      errorCategory: { type: String, default: null },
      retryEligible: { type: Boolean, default: false },
      retryReason: { type: String, default: null },
      attempts: { type: Number, default: 0 },
      lastAttemptAt: { type: Date, default: null },
    },
    processedAt: { type: Date, default: null },
  },
  { _id: false }
);

const backfillJobSchema = new mongoose.Schema(
  {
    userId: { type: mongoose.Schema.Types.ObjectId, ref: "User", required: true, index: true },
    automationId: { type: mongoose.Schema.Types.ObjectId, ref: "Automation", required: true, index: true },
    mediaId: { type: String, required: true, index: true },
    mediaCaption: { type: String, default: "" },
    mediaThumbnail: { type: String, default: null },
    status: {
      type: String,
      enum: ["pending", "processing", "completed", "completed_with_errors", "failed", "cancelled", "paused"],
      default: "pending",
      index: true,
    },
    totalComments: { type: Number, default: 0 },
    processedCount: { type: Number, default: 0 },
    successCount: { type: Number, default: 0 },
    failedCount: { type: Number, default: 0 },
    skippedCount: { type: Number, default: 0 },
    actions: [backfillActionSchema],
    error: { type: String, default: null },
    isLocked: { type: Boolean, default: false },
    lockToken: { type: String, default: null },
    lockExpiresAt: { type: Date, default: null, index: true },
    startedAt: { type: Date, default: null },
    completedAt: { type: Date, default: null },
  },
  { timestamps: true }
);

// Compound indexes
backfillJobSchema.index({ automationId: 1, createdAt: -1 });
backfillJobSchema.index({ userId: 1, mediaId: 1, status: 1 });
backfillJobSchema.index({ isLocked: 1, lockExpiresAt: 1 });

module.exports = mongoose.model("BackfillJob", backfillJobSchema);
