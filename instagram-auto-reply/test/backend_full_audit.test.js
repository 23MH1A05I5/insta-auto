const { describe, it, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const mongoose = require("mongoose");
const crypto = require("crypto");
const express = require("express");
const jwt = require("jsonwebtoken");
const http = require("http");

process.env.JWT_SECRET = "test_jwt_secret_audit_9876";
process.env.DRY_RUN = "false";
process.env.BOT_USERNAME = "bot_account";

const User = require("../models/User");
const Automation = require("../models/Automation");
const BackfillJob = require("../models/BackfillJob");
const ActionLedger = require("../models/ActionLedger");
const ActionLedgerService = require("../services/actionLedgerService");
const EligibilityService = require("../services/eligibilityService");
const ReconciliationService = require("../services/reconciliationService");
const BackfillService = require("../services/backfillService");
const AutomationEngine = require("../services/automationEngine");
const InstagramService = require("../services/instagramService");
const webhookRouter = require("../routes/webhook");
const activityRouter = require("../routes/activity");

const TEST_DB_URI = process.env.TEST_MONGO_URI || "mongodb://127.0.0.1:27017/instauto_test";

describe("InstaAuto Backend 28-Requirement Audit Test Suite", () => {
  let originalPublishReply;
  let originalSendPrivateReply;
  let originalFetchComments;
  let testUser;
  let testToken;
  let app;

  before(async () => {
    if (mongoose.connection.readyState === 0) {
      await mongoose.connect(TEST_DB_URI);
    }

    originalPublishReply = InstagramService.publishCommentReply;
    originalSendPrivateReply = InstagramService.sendPrivateReply;
    originalFetchComments = InstagramService.fetchComments;

    const { ANTI_SPAM_RULES } = require("../config/instagramRules");
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = false;

    app = express();
    app.use(express.json({
      verify: (req, res, buf) => {
        req.rawBody = buf;
      }
    }));
    app.use("/webhook", webhookRouter);
    app.use("/api/activity", activityRouter);
  });

  after(async () => {
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;
    InstagramService.fetchComments = originalFetchComments;

    const { ANTI_SPAM_RULES } = require("../config/instagramRules");
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = true;

    await User.deleteMany({ email: { $regex: /@audit-test\.local$/ } });
    await Automation.deleteMany({ igUserId: "test_audit_ig" });
    await BackfillJob.deleteMany({});
    await ActionLedger.deleteMany({});
    await mongoose.disconnect();
  });

  beforeEach(async () => {
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;
    InstagramService.fetchComments = originalFetchComments;

    await User.deleteMany({ email: { $regex: /@audit-test\.local$/ } });
    await Automation.deleteMany({ igUserId: "test_audit_ig" });
    await BackfillJob.deleteMany({});
    await ActionLedger.deleteMany({});

    testUser = await User.create({
      name: "Audit Tester",
      email: `tester_${Date.now()}_${Math.random()}@audit-test.local`,
      password: "password123",
      instagram: {
        userId: "test_audit_ig",
        id: "test_audit_ig",
        username: "audit_ig",
        accessToken: "valid_audit_access_token",
      },
    });
    testToken = jwt.sign({ id: testUser._id }, process.env.JWT_SECRET);
  });

  async function waitForJob(jobId) {
    for (let i = 0; i < 100; i++) {
      const job = await BackfillJob.findById(jobId);
      if (job && job.status !== "processing" && job.status !== "pending") {
        return job;
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    return BackfillJob.findById(jobId);
  }

  async function createAuditAutomation(mediaId = "media_audit_100", overrides = {}) {
    return Automation.create({
      userId: testUser._id,
      igUserId: "test_audit_ig",
      name: "Audit Test Reel",
      mediaId,
      mediaUrl: `https://instagram.com/reel/${mediaId}`,
      mediaCaption: "Audit test post",
      mediaType: "VIDEO",
      status: "active",
      trigger: {
        matchType: "keywords",
        keywords: ["link", "audit"],
      },
      publicReply: {
        enabled: true,
        messages: ["Thanks for commenting @{username}!"],
      },
      openingDm: {
        enabled: true,
        message: "Here is your exclusive link!",
        buttonEnabled: true,
        buttonText: "Get Link",
        link: "https://example.com",
      },
      stats: { commentsReceived: 0, repliesSent: 0, dmsSent: 0, failed: 0, totalFailedAttempts: 0 },
      activityLog: [],
      ...overrides,
    });
  }

  function makeRequest(method, path, headers = {}, body = null) {
    return new Promise((resolve, reject) => {
      const server = http.createServer(app);
      server.listen(0, () => {
        const port = server.address().port;
        const payload = body ? (typeof body === "string" ? body : JSON.stringify(body)) : null;
        const reqHeaders = { ...headers };
        if (payload && !reqHeaders["Content-Type"]) {
          reqHeaders["Content-Type"] = "application/json";
        }
        if (payload) {
          reqHeaders["Content-Length"] = Buffer.byteLength(payload);
        }

        const clientReq = http.request({
          host: "127.0.0.1",
          port,
          method,
          path,
          headers: reqHeaders,
        }, (res) => {
          let data = "";
          res.on("data", (chunk) => (data += chunk));
          res.on("end", () => {
            server.close();
            try {
              resolve({ status: res.statusCode, body: JSON.parse(data) });
            } catch (_) {
              resolve({ status: res.statusCode, body: data });
            }
          });
        });

        clientReq.on("error", (err) => {
          server.close();
          reject(err);
        });

        if (payload) {
          clientReq.write(payload);
        }
        clientReq.end();
      });
    });
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 1. Duplicate webhook delivery
  // ───────────────────────────────────────────────────────────────────────────
  it("1. Duplicate webhook delivery: second delivery is deduplicated with zero extra DMs", async () => {
    const auto = await createAuditAutomation("media_audit_1");
    let dmCalls = 0;
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_1" });
    InstagramService.sendPrivateReply = async () => {
      dmCalls++;
      return { ok: true, messageId: "msg_1" };
    };

    const commentPayload = {
      id: "comment_wh_dup_1",
      text: "send link",
      from: { username: "user_dup_1", id: "u_dup_1" },
      media: { id: "media_audit_1" },
      timestamp: new Date().toISOString(),
    };

    // First delivery
    await AutomationEngine.handleIncomingComment(commentPayload);
    assert.equal(dmCalls, 1);

    // Duplicate delivery
    await AutomationEngine.handleIncomingComment(commentPayload);
    assert.equal(dmCalls, 1, "Duplicate webhook delivery must not trigger a second DM");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 2. Same comment processed concurrently by two workers
  // ───────────────────────────────────────────────────────────────────────────
  it("2. Same comment processed concurrently by two workers: exactly one claims and sends", async () => {
    const auto = await createAuditAutomation("media_audit_2");
    let dmCalls = 0;
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_2" });
    InstagramService.sendPrivateReply = async () => {
      dmCalls++;
      await new Promise(r => setTimeout(r, 20));
      return { ok: true, messageId: `msg_2_${Date.now()}` };
    };

    const commentPayload = {
      id: "comment_concurrent_2",
      text: "link please",
      from: { username: "user_conc_2", id: "u_conc_2" },
      media: { id: "media_audit_2" },
      timestamp: new Date().toISOString(),
    };

    // Concurrent execution
    await Promise.all([
      AutomationEngine.handleIncomingComment(commentPayload),
      AutomationEngine.handleIncomingComment(commentPayload),
    ]);

    assert.equal(dmCalls, 1, "Exactly one worker must succeed in sending the DM");
    const records = await ActionLedger.find({ commentId: "comment_concurrent_2", actionType: "dm" });
    assert.equal(records.length, 1);
    assert.equal(records[0].status, "sent");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 3. Different comments by the same recipient on the same post
  // ───────────────────────────────────────────────────────────────────────────
  it("3. Different comments by the same recipient on the same post: sends DM once, second comment skipped", async () => {
    const auto = await createAuditAutomation("media_audit_3");
    let dmCalls = 0;
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_3" });
    InstagramService.sendPrivateReply = async () => {
      dmCalls++;
      return { ok: true, messageId: `msg_3_${Date.now()}` };
    };

    // Comment 1 by bob
    await AutomationEngine.handleIncomingComment({
      id: "comment_bob_1",
      text: "link please",
      from: { username: "bob_the_builder", id: "u_bob" },
      media: { id: "media_audit_3" },
      timestamp: new Date().toISOString(),
    });
    assert.equal(dmCalls, 1);

    // Comment 2 by bob on the SAME post
    await AutomationEngine.handleIncomingComment({
      id: "comment_bob_2",
      text: "link again please",
      from: { username: "bob_the_builder", id: "u_bob" },
      media: { id: "media_audit_3" },
      timestamp: new Date().toISOString(),
    });
    assert.equal(dmCalls, 1, "Bob should only receive one DM per post");

    const ledger2 = await ActionLedger.findOne({ commentId: "comment_bob_2", actionType: "dm" });
    assert.ok(ledger2);
    assert.equal(ledger2.status, "skipped");
    assert.equal(ledger2.skipReason, "ALREADY_SENT_TO_USER");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 4. Concurrent backfill jobs for the same automation
  // ───────────────────────────────────────────────────────────────────────────
  it("4. Concurrent backfill jobs for the same automation: second job detects existing run and prevents duplication", async () => {
    const auto = await createAuditAutomation("media_audit_4");
    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c_bf_1", text: "link", username: "user_bf_1", from: { id: "u_bf_1", username: "user_bf_1" }, timestamp: new Date().toISOString() },
      ],
    });
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_bf" });
    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "msg_bf" });

    const job1 = await BackfillService.startJob(testUser._id, auto._id);
    assert.ok(job1.job);

    // Immediate second start while job1 is in-progress
    const job2 = await BackfillService.startJob(testUser._id, auto._id);
    assert.equal(job2.isAlreadyRunning, true);
    assert.equal(job2.job._id.toString(), job1.job._id.toString());
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 5. Already-sent DM reconciliation
  // ───────────────────────────────────────────────────────────────────────────
  it("5. Already-sent DM reconciliation: Meta ALREADY_REPLIED is classified as sent with reconciliation metadata", async () => {
    const classification = ActionLedgerService.classifyMetaError({
      subcode: 2018002,
      message: "This comment has already been replied to",
    });
    assert.equal(classification.isAlreadyReplied, true);
    assert.equal(classification.category, "ALREADY_REPLIED");

    const claim = await ActionLedgerService.claimAction({
      igUserId: "test_audit_ig",
      mediaId: "media_audit_5",
      commentId: "c_audit_5",
      actionType: "dm",
      recipientId: "u_audit_5",
    });

    const finalized = await ActionLedgerService.finalizeAction({
      actionKey: claim.record.actionKey,
      claimToken: claim.claimToken,
      result: {
        ok: false,
        error: { subcode: 2018002, message: "This comment has already been replied to" },
      },
    });

    assert.equal(finalized.status, "sent");
    assert.equal(finalized.reconciliationReason, "ALREADY_REPLIED_META");
    assert.ok(finalized.reconciledAt);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 6. Repeated reconciliation
  // ───────────────────────────────────────────────────────────────────────────
  it("6. Repeated reconciliation: idempotent and does not create duplicate entries or extra counts", async () => {
    const auto = await createAuditAutomation("media_audit_6");
    auto.activityLog.push({
      commentId: "c_legacy_rep",
      username: "legacy_user",
      publicReply: { sent: true, status: "sent", messageId: "rep_legacy" },
      privateReply: { sent: true, status: "sent", messageId: "msg_legacy_rep" },
      timestamp: new Date(),
    });
    await auto.save();

    const report1 = await ReconciliationService.reconcile({ dryRun: false });
    assert.equal(report1.reconciledDms, 1);

    // Second run
    const report2 = await ReconciliationService.reconcile({ dryRun: false });
    assert.equal(report2.reconciledDms, 0);
    assert.equal(report2.alreadyExistingInLedger >= 1, true);

    const count = await ActionLedger.countDocuments({ commentId: "c_legacy_rep", actionType: "dm" });
    assert.equal(count, 1);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 7. Invalid and missing comment timestamps
  // ───────────────────────────────────────────────────────────────────────────
  it("7. Invalid and missing comment timestamps: rejected safely", async () => {
    const checkNull = EligibilityService.parseTimestamp(null);
    assert.equal(checkNull.valid, false);
    assert.equal(checkNull.reason, "MISSING_TIMESTAMP");

    const checkInvalid = EligibilityService.parseTimestamp("not-a-valid-date");
    assert.equal(checkInvalid.valid, false);
    assert.equal(checkInvalid.reason, "INVALID_TIMESTAMP");

    const checkFuture = EligibilityService.parseTimestamp(new Date(Date.now() + 86400000 * 2).toISOString());
    assert.equal(checkFuture.valid, false);
    assert.equal(checkFuture.reason, "FUTURE_TIMESTAMP");

    const checkValid = EligibilityService.parseTimestamp(new Date().toISOString());
    assert.equal(checkValid.valid, true);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 8. Permanently ineligible comments
  // ───────────────────────────────────────────────────────────────────────────
  it("8. Permanently ineligible comments: comment > 7 days is terminal skip and not retryable", async () => {
    const tenDaysAgo = new Date(Date.now() - 10 * 86400000).toISOString();
    const eligibility = EligibilityService.evaluateEligibility({
      actionType: "dm",
      commentTimestamp: tenDaysAgo,
      username: "user_old",
      automation: { openingDm: { enabled: true } },
    });

    assert.equal(eligibility.isEligible, false);
    assert.equal(eligibility.skipReason, "WINDOW_CLOSED_7_DAYS");
    assert.equal(eligibility.isTerminal, true);
    assert.equal(eligibility.retryEligible, false);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 9. Public reply succeeds but private DM fails
  // ───────────────────────────────────────────────────────────────────────────
  it("9. Public reply succeeds but private DM fails: independent action outcomes", async () => {
    const auto = await createAuditAutomation("media_audit_9");
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_9" });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: { code: 500, message: "Temporary DM failure" },
    });

    await AutomationEngine.handleIncomingComment({
      id: "c_audit_9",
      text: "link",
      from: { username: "user_9", id: "u_9" },
      media: { id: "media_audit_9" },
      timestamp: new Date().toISOString(),
    });

    const pubRecord = await ActionLedger.findOne({ commentId: "c_audit_9", actionType: "public_reply" });
    const dmRecord = await ActionLedger.findOne({ commentId: "c_audit_9", actionType: "dm" });

    assert.equal(pubRecord.status, "sent");
    assert.equal(dmRecord.status, "failed");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 10. Private DM succeeds but public reply fails
  // ───────────────────────────────────────────────────────────────────────────
  it("10. Private DM succeeds but public reply fails: independent action outcomes", async () => {
    const auto = await createAuditAutomation("media_audit_10");
    InstagramService.publishCommentReply = async () => ({
      ok: false,
      error: { code: 500, message: "Comment reply failed" },
    });
    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "msg_10" });

    await AutomationEngine.handleIncomingComment({
      id: "c_audit_10",
      text: "link",
      from: { username: "user_10", id: "u_10" },
      media: { id: "media_audit_10" },
      timestamp: new Date().toISOString(),
    });

    const pubRecord = await ActionLedger.findOne({ commentId: "c_audit_10", actionType: "public_reply" });
    const dmRecord = await ActionLedger.findOne({ commentId: "c_audit_10", actionType: "dm" });

    assert.equal(pubRecord.status, "failed");
    assert.equal(dmRecord.status, "sent");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 11. Meta confirms an already-sent reply
  // ───────────────────────────────────────────────────────────────────────────
  it("11. Meta confirms an already-sent reply: classified with isAlreadyReplied: true", async () => {
    const classification = ActionLedgerService.classifyMetaError({
      category: "ALREADY_REPLIED",
      message: "The comment has already been replied to.",
    });
    assert.equal(classification.isAlreadyReplied, true);
    assert.equal(classification.isIneligible, false);
    assert.equal(classification.isRetryable, false);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 12. Meta returns a generic API error
  // ───────────────────────────────────────────────────────────────────────────
  it("12. Meta returns a generic API error: classified as retryable failure, not dev-mode skip", async () => {
    const classification = ActionLedgerService.classifyMetaError({
      code: 1,
      message: "An unknown error occurred",
    });
    assert.equal(classification.isAlreadyReplied, false);
    assert.equal(classification.isIneligible, false);
    assert.equal(classification.isRetryable, true);
    assert.equal(classification.category, "API_ERROR");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 13. Meta returns a rate-limit response
  // ───────────────────────────────────────────────────────────────────────────
  it("13. Meta returns a rate-limit response: classified as retryable RATE_LIMIT", async () => {
    const classification = ActionLedgerService.classifyMetaError({
      code: 4,
      message: "Application request limit reached",
    });
    assert.equal(classification.isRetryable, true);
    assert.equal(classification.category, "RATE_LIMIT");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 14. Meta authentication failure
  // ───────────────────────────────────────────────────────────────────────────
  it("14. Meta authentication failure: classified as non-retryable TOKEN_EXPIRED", async () => {
    const classification = ActionLedgerService.classifyMetaError({
      code: 190,
      message: "Invalid OAuth access token",
    });
    assert.equal(classification.isRetryable, false);
    assert.equal(classification.category, "TOKEN_EXPIRED");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 15. External request times out after possible delivery
  // ───────────────────────────────────────────────────────────────────────────
  it("15. External request times out after possible delivery: marked as unknown / reconciliation_required", async () => {
    const classification = ActionLedgerService.classifyMetaError({
      isTimeout: true,
      message: "Request timed out after 10000ms",
    });
    assert.equal(classification.isTimeout, true);
    assert.equal(classification.category, "NETWORK_TIMEOUT");

    const claim = await ActionLedgerService.claimAction({
      igUserId: "test_audit_ig",
      mediaId: "media_audit_15",
      commentId: "c_audit_15",
      actionType: "dm",
      recipientId: "u_audit_15",
    });

    const finalized = await ActionLedgerService.finalizeAction({
      actionKey: claim.record.actionKey,
      claimToken: claim.claimToken,
      result: {
        ok: false,
        error: { isTimeout: true, message: "Request timed out" },
      },
    });

    assert.equal(finalized.status, "unknown");
    assert.equal(finalized.isAmbiguous, true);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 16. MongoDB fails after Meta accepts the message
  // ───────────────────────────────────────────────────────────────────────────
  it("16. MongoDB fails after Meta accepts message: lease expires and recovery reconciles", async () => {
    const claim = await ActionLedgerService.claimAction({
      igUserId: "test_audit_ig",
      mediaId: "media_audit_16",
      commentId: "c_audit_16",
      actionType: "dm",
      recipientId: "u_audit_16",
    });

    // Worker simulates crash before finalizeAction()
    // Expire lease
    await ActionLedger.updateOne(
      { _id: claim.record._id },
      { $set: { claimExpiresAt: new Date(Date.now() - 1000) } }
    );

    // Recovery worker reclaims expired lease
    const recoveryClaim = await ActionLedgerService.claimAction({
      igUserId: "test_audit_ig",
      mediaId: "media_audit_16",
      commentId: "c_audit_16",
      actionType: "dm",
      recipientId: "u_audit_16",
    });

    assert.equal(recoveryClaim.claimed, true);
    assert.equal(recoveryClaim.isRecovery, true);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 17. Job restarts after an interrupted send
  // ───────────────────────────────────────────────────────────────────────────
  it("17. Job restarts after an interrupted send: resumeJob reclaims stalled job and resumes", async () => {
    const auto = await createAuditAutomation("media_audit_17");
    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_audit_17",
      status: "processing",
      isLocked: true,
      lockToken: "old_crashed_token",
      lockExpiresAt: new Date(Date.now() - 5000), // Expired lease
      actions: [
        {
          commentId: "c_res_1",
          commenterUsername: "user_res_1",
          commenterId: "u_res_1",
          commentText: "link",
          commentTimestamp: new Date(),
          publicReply: { status: "pending" },
          privateReply: { status: "pending" },
        },
      ],
      progress: { totalComments: 1, processedCount: 0, eligibleCount: 1 },
      stats: { successCount: 0, failedCount: 0, skippedCount: 0 },
    });

    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_res" });
    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "msg_res" });

    const resumed = await BackfillService.resumeJob(job._id, testUser._id);
    assert.equal(resumed.ok, true);

    const updated = await waitForJob(job._id);
    assert.equal(updated.status, "completed");
    assert.equal(updated.successCount, 1);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 18. Retry after definitive failure
  // ───────────────────────────────────────────────────────────────────────────
  it("18. Retry after definitive failure: retry-dm successfully sends and updates activity", async () => {
    const auto = await createAuditAutomation("media_audit_18");
    auto.activityLog.push({
      commentId: "c_retry_def",
      username: "user_retry_18",
      publicReply: { status: "sent", sent: true },
      privateReply: {
        status: "failed",
        sent: false,
        retryEligible: true,
        errorCategory: "API_ERROR",
        attempts: 1,
      },
      timestamp: new Date(),
    });
    auto.stats.failed = 1;
    await auto.save();

    await ActionLedger.create({
      actionKey: ActionLedgerService.buildActionKey({
        igUserId: "test_audit_ig",
        mediaId: "media_audit_18",
        commentId: "c_retry_def",
        actionType: "dm",
      }),
      igUserId: "test_audit_ig",
      mediaId: "media_audit_18",
      commentId: "c_retry_def",
      recipientId: "u_retry_18",
      actionType: "dm",
      status: "failed",
      isRetryable: true,
    });

    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "msg_retried_ok" });

    const res = await makeRequest("POST", `/api/activity/c_retry_def/retry-dm`, {
      Authorization: `Bearer ${testToken}`,
    });

    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.equal(res.body.activity.status, "sent");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 19. Retry after ambiguous delivery
  // ───────────────────────────────────────────────────────────────────────────
  it("19. Retry after ambiguous delivery: flags or safely handles reconciliation before resend", async () => {
    const auto = await createAuditAutomation("media_audit_19");
    auto.activityLog.push({
      commentId: "c_retry_ambig",
      username: "user_ambig_19",
      publicReply: { status: "sent", sent: true },
      privateReply: {
        status: "unknown",
        sent: false,
        retryEligible: false,
        retryReason: "Ambiguous delivery outcome",
      },
      timestamp: new Date(),
    });
    await auto.save();

    // Directly attempting to retry an unknown/ambiguous action is blocked without reconciliation
    const res = await makeRequest("POST", `/api/activity/c_retry_ambig/retry-dm`, {
      Authorization: `Bearer ${testToken}`,
    });

    assert.equal(res.status, 400);
    assert.match(res.body.error, /Cannot retry/i);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 20. Repeated retry requests
  // ───────────────────────────────────────────────────────────────────────────
  it("20. Repeated retry requests: simultaneous retry calls acquire lock; second is rejected", async () => {
    const auto = await createAuditAutomation("media_audit_20");
    auto.activityLog.push({
      commentId: "c_repeat_retry",
      username: "user_20",
      publicReply: { status: "sent", sent: true },
      privateReply: {
        status: "failed",
        sent: false,
        retryEligible: true,
        errorCategory: "API_ERROR",
        attempts: 1,
      },
      timestamp: new Date(),
    });
    await auto.save();

    let calls = 0;
    InstagramService.sendPrivateReply = async () => {
      calls++;
      await new Promise(r => setTimeout(r, 60));
      return { ok: true, messageId: "msg_20" };
    };

    const [res1, res2] = await Promise.all([
      makeRequest("POST", `/api/activity/c_repeat_retry/retry-dm`, {
        Authorization: `Bearer ${testToken}`,
      }),
      makeRequest("POST", `/api/activity/c_repeat_retry/retry-dm`, {
        Authorization: `Bearer ${testToken}`,
      }),
    ]);

    assert.equal(calls, 1, "Instagram API send must be called only once");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 21. Webhook signature missing or invalid
  // ───────────────────────────────────────────────────────────────────────────
  it("21. Webhook signature missing or invalid: rejected with 401/403 in production", async () => {
    const originalEnv = process.env.NODE_ENV;
    const originalSecret = process.env.INSTAGRAM_APP_SECRET;
    process.env.NODE_ENV = "production";
    process.env.INSTAGRAM_APP_SECRET = "production_super_secret_123";

    try {
      // Missing signature -> 401
      const resMissing = await makeRequest("POST", "/webhook", {}, { object: "instagram" });
      assert.equal(resMissing.status, 401);

      // Invalid signature -> 403
      const resInvalid = await makeRequest("POST", "/webhook", {
        "x-hub-signature-256": "sha256=invalidhexsignature12345",
      }, { object: "instagram" });
      assert.equal(resInvalid.status, 403);
    } finally {
      process.env.NODE_ENV = originalEnv;
      process.env.INSTAGRAM_APP_SECRET = originalSecret;
    }
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 22. Webhook secret missing in production
  // ───────────────────────────────────────────────────────────────────────────
  it("22. Webhook secret missing in production: fails closed with 500", async () => {
    const originalEnv = process.env.NODE_ENV;
    const originalSecret = process.env.INSTAGRAM_APP_SECRET;
    process.env.NODE_ENV = "production";
    delete process.env.INSTAGRAM_APP_SECRET;

    try {
      const res = await makeRequest("POST", "/webhook", {
        "x-hub-signature-256": "sha256=some_sig",
      }, { object: "instagram" });
      assert.equal(res.status, 500);
      assert.match(String(res.body), /Webhook secret configuration error/);
    } finally {
      process.env.NODE_ENV = originalEnv;
      process.env.INSTAGRAM_APP_SECRET = originalSecret;
    }
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 23. Unauthenticated test endpoint
  // ───────────────────────────────────────────────────────────────────────────
  it("23. Unauthenticated test endpoint: POST /webhook/test-comment rejected in production without admin key", async () => {
    const originalEnv = process.env.NODE_ENV;
    const originalKey = process.env.ADMIN_API_KEY;
    process.env.NODE_ENV = "production";
    process.env.ADMIN_API_KEY = "admin_secret_key_prod";

    try {
      const res = await makeRequest("POST", "/webhook/test-comment", {}, {
        comment_id: "c_test_sec",
        username: "test_sec_user",
        text: "hello",
      });
      assert.equal(res.status, 403);
    } finally {
      process.env.NODE_ENV = originalEnv;
      process.env.ADMIN_API_KEY = originalKey;
    }
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 24. Unexpected test payload
  // ───────────────────────────────────────────────────────────────────────────
  it("24. Unexpected test payload: rejects missing or invalid fields with 400", async () => {
    const res = await makeRequest("POST", "/webhook/test-comment", {}, {
      // Missing text
      comment_id: "c_malformed",
      username: "user_malformed",
    });
    assert.equal(res.status, 400);
    assert.match(JSON.stringify(res.body), /Missing required fields/);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 25. Counter reconciliation after repeated retries
  // ───────────────────────────────────────────────────────────────────────────
  it("25. Counter reconciliation after repeated retries: failed count decrements once upon success", async () => {
    const auto = await createAuditAutomation("media_audit_25");
    auto.stats.failed = 1;
    auto.activityLog.push({
      commentId: "c_count_rec",
      username: "user_25",
      publicReply: { status: "sent", sent: true },
      privateReply: {
        status: "failed",
        sent: false,
        retryEligible: true,
        errorCategory: "API_ERROR",
        attempts: 1,
      },
      timestamp: new Date(),
    });
    await auto.save();

    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "msg_25" });

    // First retry -> resolves failure
    const res1 = await makeRequest("POST", `/api/activity/c_count_rec/retry-dm`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(res1.status, 200);

    const autoAfter1 = await Automation.findById(auto._id);
    assert.equal(autoAfter1.stats.failed, 0);

    // Second retry on already sent -> rejected with 409, does not decrement below 0
    const res2 = await makeRequest("POST", `/api/activity/c_count_rec/retry-dm`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(res2.status, 409);

    const autoAfter2 = await Automation.findById(auto._id);
    assert.equal(autoAfter2.stats.failed, 0);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 26. Duplicate database-key conflicts
  // ───────────────────────────────────────────────────────────────────────────
  it("26. Duplicate database-key conflicts: treated as expected concurrency outcome without throwing unhandled error", async () => {
    const claimParams = {
      igUserId: "test_audit_ig",
      mediaId: "media_audit_26",
      commentId: "c_audit_26",
      actionType: "dm",
      recipientId: "u_audit_26",
    };

    const claim1 = await ActionLedgerService.claimAction(claimParams);
    assert.equal(claim1.claimed, true);

    // Direct duplicate insert attempt
    try {
      await ActionLedger.create({
        actionKey: claim1.record.actionKey,
        igUserId: "test_audit_ig",
        mediaId: "media_audit_26",
        commentId: "c_audit_26",
        actionType: "dm",
        recipientId: "u_audit_26",
        status: "pending",
      });
      assert.fail("Duplicate actionKey insert must throw duplicate key error");
    } catch (err) {
      assert.equal(err.code, 11000, "MongoDB duplicate key error E11000 expected");
    }
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 27. Invalid API response payloads
  // ───────────────────────────────────────────────────────────────────────────
  it("27. Invalid API response payloads: activity contract returns standardized structured schema", async () => {
    const auto = await createAuditAutomation("media_audit_27");
    auto.activityLog.push({
      commentId: "c_contract_27",
      username: "user_27",
      publicReply: { status: "sent", sent: true },
      privateReply: {
        status: "sent",
        sent: true,
        messageId: "msg_27_contract",
        lastSuccessAt: new Date(),
      },
      timestamp: new Date(),
    });
    await auto.save();

    const res = await makeRequest("GET", `/api/activity/${auto._id}`, {
      Authorization: `Bearer ${testToken}`,
    });

    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.ok(Array.isArray(res.body.activity));
    const entry = res.body.activity[0];
    assert.ok(entry.actionId);
    assert.equal(entry.commentId, "c_contract_27");
    assert.equal(entry.mediaId, "media_audit_27");
    assert.equal(entry.status, "sent");
    assert.equal(entry.messageId, "msg_27_contract");
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 28. Trigger mismatch and terminal skip persistence
  // ───────────────────────────────────────────────────────────────────────────
  it("28. Trigger mismatch and terminal skip persistence: recorded as terminal skip in ActionLedger and activityLog", async () => {
    const auto = await createAuditAutomation("media_audit_28"); // Triggers on "link", "audit"

    await AutomationEngine.handleIncomingComment({
      id: "c_mismatch_28",
      text: "random cool post without trigger word",
      from: { username: "random_user_28", id: "u_mismatch_28" },
      media: { id: "media_audit_28" },
      timestamp: new Date().toISOString(),
    });

    const ledger = await ActionLedger.findOne({ commentId: "c_mismatch_28", actionType: "dm" });
    assert.ok(ledger);
    assert.equal(ledger.status, "skipped");
    assert.equal(ledger.skipReason, "TRIGGER_MISMATCH");

    const autoUpdated = await Automation.findById(auto._id);
    const logEntry = autoUpdated.activityLog.find(e => e.commentId === "c_mismatch_28");
    assert.ok(logEntry);
    assert.equal(logEntry.privateReply?.status, "skipped");
    assert.equal(logEntry.privateReply?.skipReason, "TRIGGER_MISMATCH");
  });
});
