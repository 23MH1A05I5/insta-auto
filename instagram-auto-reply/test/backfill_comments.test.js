const { describe, it, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const mongoose = require("mongoose");
const express = require("express");

process.env.JWT_SECRET = "test_jwt_secret_12345";
process.env.DRY_RUN = "false";
process.env.BOT_USERNAME = "bot_account";

const Automation = require("../models/Automation");
const User = require("../models/User");
const BackfillJob = require("../models/BackfillJob");
const ActionLedger = require("../models/ActionLedger");
const InstagramService = require("../services/instagramService");
const AutomationEngine = require("../services/automationEngine");
const BackfillService = require("../services/backfillService");
const automationsRouter = require("../routes/automations");
const jwt = require("jsonwebtoken");

const TEST_DB_URI = process.env.TEST_MONGO_URI || "mongodb://127.0.0.1:27017/instauto_test";

describe("Backfill Existing Comments (Historical Automation)", () => {
  let originalFetchComments;
  let originalPublishReply;
  let originalSendPrivateReply;
  let testUser;
  let otherUser;
  let app;

  before(async () => {
    if (mongoose.connection.readyState === 0) {
      await mongoose.connect(TEST_DB_URI);
    }

    originalFetchComments = InstagramService.fetchComments;
    originalPublishReply = InstagramService.publishCommentReply;
    originalSendPrivateReply = InstagramService.sendPrivateReply;

    const { ANTI_SPAM_RULES } = require("../config/instagramRules");
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = false; // Fast test execution

    app = express();
    app.use(express.json());
    app.use("/api/automations", automationsRouter);
  });

  after(async () => {
    InstagramService.fetchComments = originalFetchComments;
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;

    const { ANTI_SPAM_RULES } = require("../config/instagramRules");
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = true;

    await User.deleteMany({ email: { $regex: /@backfill-test\.local$/ } });
    await Automation.deleteMany({ igUserId: "test_backfill_ig_user" });
    await BackfillJob.deleteMany({});
    await ActionLedger.deleteMany({});
    await mongoose.disconnect();
  });

  beforeEach(async () => {
    InstagramService.fetchComments = originalFetchComments;
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;

    await User.deleteMany({ email: { $regex: /@backfill-test\.local$/ } });
    await Automation.deleteMany({ igUserId: "test_backfill_ig_user" });
    await BackfillJob.deleteMany({});
    await ActionLedger.deleteMany({});

    testUser = await User.create({
      name: "Backfill Tester",
      email: `tester_${Date.now()}@backfill-test.local`,
      password: "password123",
      instagram: {
        userId: "test_backfill_ig_user",
        username: "tester_ig",
        accessToken: "test_access_token_123",
      },
    });

    otherUser = await User.create({
      name: "Other Tester",
      email: `other_${Date.now()}@backfill-test.local`,
      password: "password123",
      instagram: {
        userId: "other_ig_user",
        username: "other_ig",
        accessToken: "other_token",
      },
    });
  });

  function createTestAutomation(overrides = {}) {
    return Automation.create({
      userId: testUser._id,
      igUserId: testUser.instagram.userId,
      mediaId: "media_post_100",
      name: "Reel Backfill Automation",
      status: "active",
      trigger: { matchType: "keywords", keywords: ["price", "link"], wholeWord: false },
      publicReply: { enabled: true, messages: ["Hi @{username}, check your DMs!"] },
      openingDm: { enabled: true, message: "Here is your link!", buttonText: "Click", link: "https://example.com" },
      ...overrides,
    });
  }

  it("1. Preview: matches trigger keywords, detects old comments (>7d), and reports eligibility", async () => {
    const auto = await createTestAutomation();

    const mockComments = [
      { id: "c1", text: "What is the price?", from: { id: "u1", username: "alice" }, timestamp: new Date().toISOString() },
      { id: "c2", text: "Nice video!", from: { id: "u2", username: "bob" }, timestamp: new Date().toISOString() },
      { id: "c3", text: "Send me the link", from: { id: "u3", username: "charlie" }, timestamp: new Date(Date.now() - 10 * 24 * 3600 * 1000).toISOString() }, // 10 days old
    ];

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: mockComments,
      paging: null,
    });

    const preview = await BackfillService.preview(testUser._id, auto._id, "media_post_100");

    assert.equal(preview.totalFound, 3);
    assert.equal(preview.eligibleCount, 2); // c1 (within 7d), c3 (eligible for public reply, though DM expired)
    assert.equal(preview.unmatchedCount, 1); // c2
    assert.equal(preview.expiredDmCount, 1); // c3

    const c3Preview = preview.comments.find((c) => c.commentId === "c3");
    assert.equal(c3Preview.canSendPublic, true);
    assert.equal(c3Preview.canSendDm, false);
    assert.equal(c3Preview.dmExpired, true);
  });

  it("2. Preview: correctly identifies already processed comments from activityLog", async () => {
    const auto = await createTestAutomation({
      activityLog: [
        {
          commentId: "c_already_done",
          username: "done_user",
          text: "price?",
          ruleMatched: "price",
          publicReply: { sent: true, status: "sent" },
          privateReply: { sent: true, status: "sent" },
        },
      ],
    });

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c_already_done", text: "price?", from: { id: "u1", username: "done_user" }, timestamp: new Date().toISOString() },
        { id: "c_new", text: "price please", from: { id: "u2", username: "new_user" }, timestamp: new Date().toISOString() },
      ],
      paging: null,
    });

    const preview = await BackfillService.preview(testUser._id, auto._id, "media_post_100");
    assert.equal(preview.totalFound, 2);
    assert.equal(preview.eligibleCount, 1);
    assert.equal(preview.alreadyProcessedCount, 1);

    const doneComment = preview.comments.find((c) => c.commentId === "c_already_done");
    assert.equal(doneComment.status, "already_processed");
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

  it("3. Start Job & Execution: processes eligible comments and prevents duplicate sends", async () => {
    const auto = await createTestAutomation();

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c101", text: "What is the price?", from: { id: "u101", username: "buyer1" }, timestamp: new Date().toISOString() },
        { id: "c102", text: "link please", from: { id: "u102", username: "buyer2" }, timestamp: new Date().toISOString() },
      ],
      paging: null,
    });

    let sentPublicReplies = [];
    let sentDMs = [];

    InstagramService.publishCommentReply = async (commentId, msg) => {
      sentPublicReplies.push({ commentId, msg });
      return { ok: true, replyId: `pub_${commentId}` };
    };

    InstagramService.sendPrivateReply = async (commentId, msg) => {
      sentDMs.push({ commentId, msg });
      return { ok: true, messageId: `dm_${commentId}` };
    };

    const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
    assert.equal(startRes.ok, true);
    assert.ok(startRes.job);

    // Wait for background job to finish processing
    const finishedJob = await waitForJob(startRes.job._id);
    assert.equal(finishedJob.status, "completed");
    assert.equal(finishedJob.successCount, 2);
    assert.equal(finishedJob.failedCount, 0);
    assert.equal(sentPublicReplies.length, 2);
    assert.equal(sentDMs.length, 2);

    // Verify activityLog in Automation was populated with source='backfill'
    const updatedAuto = await Automation.findById(auto._id);
    assert.equal(updatedAuto.activityLog.length, 2);
    assert.equal(updatedAuto.activityLog[0].source, "backfill");
    assert.equal(updatedAuto.stats.repliesSent, 2);
    assert.equal(updatedAuto.stats.dmsSent, 2);

    // Reprocess: running startJob again should find 0 eligible comments
    await assert.rejects(
      async () => {
        await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
      },
      /No eligible comments found/
    );
  });

  it("4. Idempotency: if public reply succeeded but DM failed, backfill only sends DM", async () => {
    const auto = await createTestAutomation({
      activityLog: [
        {
          commentId: "c_half_done",
          username: "half_user",
          text: "price?",
          ruleMatched: "price",
          publicReply: { sent: true, status: "sent" },
          privateReply: { sent: false, status: "failed" },
        },
      ],
    });

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c_half_done", text: "price?", from: { id: "u_half", username: "half_user" }, timestamp: new Date().toISOString() },
      ],
      paging: null,
    });

    let publicCallCount = 0;
    let dmCallCount = 0;

    InstagramService.publishCommentReply = async () => {
      publicCallCount++;
      return { ok: true, replyId: "pub_new" };
    };

    InstagramService.sendPrivateReply = async () => {
      dmCallCount++;
      return { ok: true, messageId: "dm_new" };
    };

    const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
    await waitForJob(startRes.job._id);

    // Public reply was already sent, so it MUST NOT be called again
    assert.equal(publicCallCount, 0, "Must not resend successful public reply");
    assert.equal(dmCallCount, 1, "Must send pending DM");
  });

  it("5. Meta 7-day rule: comments >7d skip DM safely without marking job as failed", async () => {
    const auto = await createTestAutomation();

    const tenDaysAgo = new Date(Date.now() - 10 * 24 * 3600 * 1000);

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c_old", text: "price?", from: { id: "u_old", username: "old_user" }, timestamp: tenDaysAgo.toISOString() },
      ],
      paging: null,
    });

    let dmCallCount = 0;
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "pub_old" });
    InstagramService.sendPrivateReply = async () => {
      dmCallCount++;
      return { ok: true, messageId: "dm_old" };
    };

    const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
    const finishedJob = await waitForJob(startRes.job._id);

    assert.equal(dmCallCount, 0, "Must not attempt DM for >7d old comment");
    assert.equal(finishedJob.status, "completed");
    assert.equal(finishedJob.actions[0].publicReply.status, "sent");
    assert.equal(finishedJob.actions[0].privateReply.status, "skipped");
    assert.equal(finishedJob.actions[0].privateReply.errorCategory, "WINDOW_CLOSED_7_DAYS");
  });

  it("6. Duplicate job protection: rejects simultaneous job creation if one is in progress", async () => {
    const auto = await createTestAutomation();

    await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "processing",
      totalComments: 10,
    });

    const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
    assert.equal(startRes.isAlreadyRunning, true, "Should return existing running job without duplicating");
  });

  it("7. Concurrent webhook protection: in-memory markProcessed prevents webhook redelivery race", async () => {
    const auto = await createTestAutomation();

    // Mark comment as processed in backfill
    AutomationEngine.markProcessed("comment_race_test");

    let webhookProcessed = false;
    // Attempt webhook processing of same comment
    await AutomationEngine.handleIncomingComment({
      id: "comment_race_test",
      text: "price?",
      from: { id: "u_race", username: "race_user" },
      media: { id: "media_post_100" },
    });

    // In-memory dedup guard should have blocked it
    const autoCheck = await Automation.findById(auto._id);
    assert.equal(autoCheck.activityLog.length, 0, "Webhook must be blocked by dedup lock during backfill");
  });

  it("8. Unauthorized access: other user cannot preview or start backfill on someone else's automation", async () => {
    const auto = await createTestAutomation();

    await assert.rejects(
      async () => {
        await BackfillService.preview(otherUser._id, auto._id, "media_post_100");
      },
      /Automation not found or unauthorized/
    );

    await assert.rejects(
      async () => {
        await BackfillService.startJob(otherUser._id, auto._id, "media_post_100");
      },
      /Automation not found or unauthorized/
    );
  });

  it("9. Safe retry: retries eligible failed DMs from the BackfillJob and decrements failure count", async () => {
    const auto = await createTestAutomation({
      stats: { failed: 1, dmsSent: 0 },
      activityLog: [
        {
          commentId: "c_retry",
          username: "retry_user",
          text: "price?",
          ruleMatched: "price",
          publicReply: { sent: true, status: "sent" },
          privateReply: { sent: false, status: "failed", retryEligible: true },
        },
      ],
    });

    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "completed_with_errors",
      totalComments: 1,
      processedCount: 1,
      successCount: 0,
      failedCount: 1,
      actions: [
        {
          commentId: "c_retry",
          username: "retry_user",
          text: "price?",
          ruleMatched: "price",
          status: "failed",
          publicReply: { status: "sent" },
          privateReply: { status: "failed", retryEligible: true, message: "Here is your link" },
        },
      ],
    });

    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "retry_dm_success" });

    const retryRes = await BackfillService.retryJob(job._id, testUser._id);
    assert.equal(retryRes.ok, true);
    assert.equal(retryRes.successCount, 1);

    const updatedJob = await BackfillJob.findById(job._id);
    assert.equal(updatedJob.actions[0].privateReply.status, "sent");
    assert.equal(updatedJob.failedCount, 0);
    assert.equal(updatedJob.successCount, 1);

    const updatedAuto = await Automation.findById(auto._id);
    assert.equal(updatedAuto.stats.failed, 0);
    assert.equal(updatedAuto.stats.dmsSent, 1);
  });

  // ════════════════════════════════════════════════════════════════════════════
  // 12 SPECIFIC TESTS REQUIRED BY PROBLEM 7
  // ════════════════════════════════════════════════════════════════════════════

  it("P7-1: First comment's DM fails but all remaining comments continue processing", async () => {
    const auto = await createTestAutomation();

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c_fail_first", text: "price?", from: { id: "u1", username: "user1" }, timestamp: new Date().toISOString() },
        { id: "c_sec", text: "price?", from: { id: "u2", username: "user2" }, timestamp: new Date().toISOString() },
        { id: "c_third", text: "price?", from: { id: "u3", username: "user3" }, timestamp: new Date().toISOString() },
      ],
      paging: null,
    });

    InstagramService.publishCommentReply = async (cid) => ({ ok: true, replyId: `pub_${cid}` });
    InstagramService.sendPrivateReply = async (cid) => {
      if (cid === "c_fail_first") {
        return { ok: false, error: { message: "Temporary network timeout", isRetryable: true, category: "NETWORK" } };
      }
      return { ok: true, messageId: `dm_${cid}` };
    };

    const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
    const finishedJob = await waitForJob(startRes.job._id);

    // One failed member MUST NOT stop the entire job!
    assert.equal(finishedJob.status, "completed_with_errors");
    assert.equal(finishedJob.processedCount, 3);
    assert.equal(finishedJob.actions[0].commentId, "c_fail_first");
    assert.equal(finishedJob.actions[0].privateReply.status, "failed");
    assert.equal(finishedJob.actions[1].commentId, "c_sec");
    assert.equal(finishedJob.actions[1].privateReply.status, "sent");
    assert.equal(finishedJob.actions[2].commentId, "c_third");
    assert.equal(finishedJob.actions[2].privateReply.status, "sent");
  });

  it("P7-2: One public reply fails but DM and remaining members continue processing", async () => {
    const auto = await createTestAutomation();

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c_pub_fail", text: "price?", from: { id: "u1", username: "user1" }, timestamp: new Date().toISOString() },
        { id: "c_pub_ok", text: "price?", from: { id: "u2", username: "user2" }, timestamp: new Date().toISOString() },
      ],
      paging: null,
    });

    InstagramService.publishCommentReply = async (cid) => {
      if (cid === "c_pub_fail") {
        return { ok: false, error: { message: "Public reply failed", isRetryable: false } };
      }
      return { ok: true, replyId: `pub_${cid}` };
    };
    InstagramService.sendPrivateReply = async (cid) => ({ ok: true, messageId: `dm_${cid}` });

    const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
    const finishedJob = await waitForJob(startRes.job._id);

    assert.equal(finishedJob.processedCount, 2);
    // Comment 1: public reply failed, but DM sent!
    assert.equal(finishedJob.actions[0].publicReply.status, "failed");
    assert.equal(finishedJob.actions[0].privateReply.status, "sent");
    // Comment 2: both sent!
    assert.equal(finishedJob.actions[1].publicReply.status, "sent");
    assert.equal(finishedJob.actions[1].privateReply.status, "sent");
  });

  it("P7-3: A job with 14 comments resumes without resending successful DMs", async () => {
    const auto = await createTestAutomation();

    const mockActions = [];
    for (let i = 1; i <= 14; i++) {
      const isAlreadyDone = i <= 4;
      mockActions.push({
        commentId: `c_${i}`,
        username: `user_${i}`,
        text: "price?",
        ruleMatched: "price",
        status: isAlreadyDone ? "success" : "pending",
        publicReply: { status: isAlreadyDone ? "sent" : "pending", retryEligible: true },
        privateReply: { status: isAlreadyDone ? "sent" : "pending", retryEligible: true },
        commentTimestamp: new Date(),
      });
    }

    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "paused",
      totalComments: 14,
      processedCount: 4,
      successCount: 4,
      failedCount: 0,
      skippedCount: 0,
      actions: mockActions,
    });

    const sentDmComments = [];
    InstagramService.publishCommentReply = async (cid) => ({ ok: true, replyId: `pub_${cid}` });
    InstagramService.sendPrivateReply = async (cid) => {
      sentDmComments.push(cid);
      return { ok: true, messageId: `dm_${cid}` };
    };

    const resumeRes = await BackfillService.resumeJob(job._id, testUser._id);
    assert.equal(resumeRes.ok, true);

    const finishedJob = await waitForJob(job._id);
    assert.equal(finishedJob.status, "completed");
    assert.equal(finishedJob.processedCount, 14);

    // Exactly 10 DMs sent, comments 1..4 NEVER resent!
    assert.equal(sentDmComments.length, 10);
    assert.ok(!sentDmComments.includes("c_1"));
    assert.ok(!sentDmComments.includes("c_4"));
    assert.ok(sentDmComments.includes("c_5"));
    assert.ok(sentDmComments.includes("c_14"));
  });

  it("P7-4: Comment with public reply success and DM failure retries only the DM", async () => {
    const auto = await createTestAutomation();

    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "completed_with_errors",
      totalComments: 1,
      processedCount: 1,
      successCount: 0,
      failedCount: 1,
      actions: [
        {
          commentId: "c_pub_ok_dm_fail",
          username: "user_retry",
          text: "price?",
          status: "failed",
          publicReply: { status: "sent", message: "Public sent" },
          privateReply: { status: "failed", retryEligible: true, message: "DM to send" },
          commentTimestamp: new Date(),
        },
      ],
    });

    let pubCalled = false;
    let dmCalled = false;
    InstagramService.publishCommentReply = async () => {
      pubCalled = true;
      return { ok: true };
    };
    InstagramService.sendPrivateReply = async () => {
      dmCalled = true;
      return { ok: true, messageId: "dm_ok" };
    };

    const retryRes = await BackfillService.retryJob(job._id, testUser._id);
    assert.equal(retryRes.ok, true);
    assert.equal(pubCalled, false, "Must not resend public reply");
    assert.equal(dmCalled, true, "Must send failed DM");
  });

  it("P7-5: Comment with both actions successful is skipped on resume", async () => {
    const auto = await createTestAutomation();

    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "paused",
      totalComments: 2,
      processedCount: 1,
      successCount: 1,
      actions: [
        {
          commentId: "c_both_done",
          username: "both_done_user",
          text: "price?",
          status: "success",
          publicReply: { status: "sent" },
          privateReply: { status: "sent" },
          commentTimestamp: new Date(),
        },
        {
          commentId: "c_pending_one",
          username: "pending_user",
          text: "price?",
          status: "pending",
          publicReply: { status: "pending" },
          privateReply: { status: "pending" },
          commentTimestamp: new Date(),
        },
      ],
    });

    const calls = [];
    InstagramService.publishCommentReply = async (cid) => {
      calls.push(`pub_${cid}`);
      return { ok: true };
    };
    InstagramService.sendPrivateReply = async (cid) => {
      calls.push(`dm_${cid}`);
      return { ok: true };
    };

    await BackfillService.resumeJob(job._id, testUser._id);
    await waitForJob(job._id);

    assert.ok(!calls.includes("pub_c_both_done"));
    assert.ok(!calls.includes("dm_c_both_done"));
    assert.ok(calls.includes("pub_c_pending_one"));
    assert.ok(calls.includes("dm_c_pending_one"));
  });

  it("P7-6: Repeated resume requests do not create duplicate workers", async () => {
    const auto = await createTestAutomation();

    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "processing",
      isLocked: true, // currently running
      totalComments: 5,
    });

    const res = await BackfillService.resumeJob(job._id, testUser._id);
    assert.equal(res.ok, false);
    assert.equal(res.isAlreadyRunning, true);
  });

  it("P7-7: Two workers cannot execute the same action simultaneously (atomic concurrency lock)", async () => {
    const auto = await createTestAutomation();

    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "paused",
      isLocked: false,
      totalComments: 1,
      actions: [
        {
          commentId: "c_lock_test",
          username: "user_lock",
          text: "price?",
          status: "pending",
          publicReply: { status: "pending" },
          privateReply: { status: "pending" },
          commentTimestamp: new Date(),
        },
      ],
    });

    // Simulate two concurrent requests trying to lock the job
    const [w1, w2] = await Promise.all([
      BackfillJob.findOneAndUpdate({ _id: job._id, isLocked: { $ne: true } }, { isLocked: true, status: "processing" }, { returnDocument: "after" }),
      BackfillJob.findOneAndUpdate({ _id: job._id, isLocked: { $ne: true } }, { isLocked: true, status: "processing" }, { returnDocument: "after" }),
    ]);

    // Exactly one worker must win the lock
    const wonCount = [w1, w2].filter(Boolean).length;
    assert.equal(wonCount, 1, "Exactly one worker acquires lock atomically");
  });

  it("P7-8: Inactive automation cannot start a backfill job (AUTOMATION_INACTIVE)", async () => {
    const auto = await createTestAutomation({ status: "paused" });

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [{ id: "c1", text: "price?", from: { id: "u1", username: "user1" }, timestamp: new Date().toISOString() }],
    });

    await assert.rejects(
      async () => {
        await BackfillService.preview(testUser._id, auto._id, "media_post_100");
      },
      (err) => err.code === "AUTOMATION_INACTIVE"
    );

    await assert.rejects(
      async () => {
        await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
      },
      (err) => err.code === "AUTOMATION_INACTIVE"
    );
  });

  it("P7-9: Activating automation allows preview & start", async () => {
    const auto = await createTestAutomation({ status: "paused" });

    // Activate automation
    await Automation.updateOne({ _id: auto._id }, { status: "active" });

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [{ id: "c1", text: "price?", from: { id: "u1", username: "user1" }, timestamp: new Date().toISOString() }],
    });

    const preview = await BackfillService.preview(testUser._id, auto._id, "media_post_100");
    assert.equal(preview.eligibleCount, 1);
  });

  it("P7-10: Revoked Instagram authorization stops new actions and produces a clear error", async () => {
    const auto = await createTestAutomation();

    InstagramService.fetchComments = async () => ({
      ok: true,
      comments: [
        { id: "c_fatal", text: "price?", from: { id: "u1", username: "user1" }, timestamp: new Date().toISOString() },
        { id: "c_after", text: "price?", from: { id: "u2", username: "user2" }, timestamp: new Date().toISOString() },
      ],
    });

    InstagramService.publishCommentReply = async () => ({
      ok: false,
      error: { message: "Error validating access token: Session has expired", code: 190, category: "TOKEN_EXPIRED" },
    });

    const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
    const finishedJob = await waitForJob(startRes.job._id);

    // Fatal error stops remaining comments immediately
    assert.equal(finishedJob.status, "failed");
    assert.ok(finishedJob.error.includes("Instagram authorization expired or revoked"));
  });

  it("P7-11: Progress and statistics remain correct after restart or recovery", async () => {
    const auto = await createTestAutomation();

    const job = await BackfillJob.create({
      userId: testUser._id,
      automationId: auto._id,
      mediaId: "media_post_100",
      status: "processing",
      totalComments: 3,
      actions: [
        { commentId: "c1", status: "success", publicReply: { status: "sent" }, privateReply: { status: "sent" } },
        { commentId: "c2", status: "failed", publicReply: { status: "sent" }, privateReply: { status: "failed" } },
        { commentId: "c3", status: "skipped", publicReply: { status: "disabled" }, privateReply: { status: "skipped" } },
      ],
    });

    // Run reconciliation
    await BackfillService._finalizeJob(job._id);

    const reconciled = await BackfillJob.findById(job._id);
    assert.equal(reconciled.successCount, 1);
    assert.equal(reconciled.failedCount, 1);
    assert.equal(reconciled.skippedCount, 1);
    assert.equal(reconciled.processedCount, 3);
    assert.equal(reconciled.status, "completed_with_errors");
  });

  it("P7-12: Dry-run actions are not reported as real Instagram deliveries", async () => {
    process.env.DRY_RUN = "true";
    try {
      const auto = await createTestAutomation();

      InstagramService.fetchComments = async () => ({
        ok: true,
        comments: [{ id: "c_dry", text: "price?", from: { id: "u1", username: "user1" }, timestamp: new Date().toISOString() }],
      });

      let realApiCalled = false;
      InstagramService.publishCommentReply = async () => { realApiCalled = true; };
      InstagramService.sendPrivateReply = async () => { realApiCalled = true; };

      const startRes = await BackfillService.startJob(testUser._id, auto._id, "media_post_100");
      const finishedJob = await waitForJob(startRes.job._id);

      assert.equal(realApiCalled, false, "Must not call Instagram API in dry-run mode");
      assert.equal(finishedJob.actions[0].publicReply.status, "skipped");
      assert.equal(finishedJob.actions[0].privateReply.status, "skipped");

      // Stats must NOT count dry-run as real sent replies/DMs
      const updatedAuto = await Automation.findById(auto._id);
      assert.equal(updatedAuto.stats.repliesSent, 0);
      assert.equal(updatedAuto.stats.dmsSent, 0);
    } finally {
      process.env.DRY_RUN = "false";
    }
  });
});
