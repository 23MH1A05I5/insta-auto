const { describe, it, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const mongoose = require("mongoose");
const express = require("express");

// Set environment for testing
process.env.JWT_SECRET = "test_jwt_secret_12345";
process.env.DRY_RUN = "false";
process.env.BOT_USERNAME = "bot_account";

const Automation = require("../models/Automation");
const User = require("../models/User");
const ActionLedger = require("../models/ActionLedger");
const InstagramService = require("../services/instagramService");
const AutomationEngine = require("../services/automationEngine");
const activityRouter = require("../routes/activity");
const jwt = require("jsonwebtoken");

const TEST_DB_URI = process.env.TEST_MONGO_URI || "mongodb://127.0.0.1:27017/instauto_test";

describe("Failed Actions Logic, Backend Bugs, and Safe Retry DM", () => {
  let originalPublishReply;
  let originalSendPrivateReply;
  let testUser;
  let testUserToken;
  let otherUser;
  let otherUserToken;
  let app;

  before(async () => {
    // Connect to test MongoDB database
    if (mongoose.connection.readyState === 0) {
      await mongoose.connect(TEST_DB_URI);
    }

    // Save original service methods for restoration
    originalPublishReply = InstagramService.publishCommentReply;
    originalSendPrivateReply = InstagramService.sendPrivateReply;
    const { ANTI_SPAM_RULES } = require("../config/instagramRules");
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = false; // Fast test execution

    // Setup minimal express app for route tests
    app = express();
    app.use(express.json());
    app.use("/api/activity", activityRouter);
  });

  after(async () => {
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;
    const { ANTI_SPAM_RULES } = require("../config/instagramRules");
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = true;
    await User.deleteMany({ email: { $regex: /@test\.local$/ } });
    await Automation.deleteMany({ igUserId: "test_ig_user" });
    await ActionLedger.deleteMany({});
    await mongoose.disconnect();
  });

  beforeEach(async () => {
    // Reset service stubs
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;

    // Clean up test collections before each test
    await Automation.deleteMany({ igUserId: "test_ig_user" });
    await User.deleteMany({ email: { $regex: /@test\.local$/ } });
    await ActionLedger.deleteMany({});

    // Create test user
    testUser = await User.create({
      name: "Owner User",
      email: "owner@test.local",
      password: "password123",
      instagram: {
        userId: "test_ig_user",
        username: "test_creator",
        accessToken: "valid_test_token_abc",
      },
    });
    testUserToken = jwt.sign({ id: testUser._id }, process.env.JWT_SECRET);

    // Create second user for authorization checks
    otherUser = await User.create({
      name: "Other User",
      email: "other@test.local",
      password: "password123",
      instagram: {
        userId: "other_ig_user",
        username: "other_creator",
        accessToken: "other_token_xyz",
      },
    });
    otherUserToken = jwt.sign({ id: otherUser._id }, process.env.JWT_SECRET);
  });

  // Helper to create an active test automation
  async function createTestAutomation(overrides = {}) {
    return Automation.create({
      userId: testUser._id,
      igUserId: "test_ig_user",
      mediaId: "media_1001",
      name: "Test Reel Automation",
      status: "active",
      trigger: { matchType: "any", keywords: [] },
      publicReply: { enabled: true, messages: ["Thanks for commenting @{username}!"] },
      openingDm: { enabled: true, message: "Hey @{username}, here is your link!", buttonText: "Get Link", link: "https://example.com" },
      stats: { commentsReceived: 0, repliesSent: 0, dmsSent: 0, failed: 0, totalFailedAttempts: 0 },
      activityLog: [],
      ...overrides,
    });
  }

  // ── 1. Public reply fails and DM succeeds: one outstanding failure ────────────
  it("1. Public reply fails and DM succeeds: records one outstanding failure", async () => {
    const auto = await createTestAutomation();

    InstagramService.publishCommentReply = async () => ({
      ok: false,
      error: { message: "Spam block on comment reply", code: 368, category: "ACTION_BLOCKED" },
    });
    InstagramService.sendPrivateReply = async () => ({
      ok: true,
      messageId: "dm_success_1",
    });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_1",
      text: "hello world",
      from: { username: "commenter1", id: "user_1" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    const updated = await Automation.findById(auto._id);
    assert.equal(updated.stats.failed, 1, "Should record exactly 1 failed action");
    assert.equal(updated.stats.repliesSent, 0, "Public reply should not count as sent");
    assert.equal(updated.stats.dmsSent, 1, "DM should count as sent");
    assert.equal(updated.activityLog.length, 1);
    assert.equal(updated.activityLog[0].publicReply.status, "failed");
    assert.equal(updated.activityLog[0].privateReply.status, "sent");
    assert.ok(updated.activityLog[0].error.includes("[Public Reply]"));
  });

  // ── 2. Public reply succeeds and DM fails: one outstanding failure ────────────
  it("2. Public reply succeeds and DM fails: records one outstanding failure", async () => {
    const auto = await createTestAutomation();

    InstagramService.publishCommentReply = async () => ({
      ok: true,
      replyId: "reply_123",
    });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: { message: "Rate limit reached", code: 4, category: "RATE_LIMIT", isRetryable: true },
    });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_2",
      text: "send me link",
      from: { username: "commenter2", id: "user_2" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    const updated = await Automation.findById(auto._id);
    assert.equal(updated.stats.failed, 1, "Should record exactly 1 failed action");
    assert.equal(updated.stats.repliesSent, 1, "Public reply should count as sent");
    assert.equal(updated.stats.dmsSent, 0, "DM should not count as sent");
    assert.equal(updated.activityLog[0].publicReply.status, "sent");
    assert.equal(updated.activityLog[0].privateReply.status, "failed");
    assert.equal(updated.activityLog[0].privateReply.retryEligible, true);
    assert.ok(updated.activityLog[0].error.includes("[DM]"));
  });

  // ── 3. Both actions fail: two outstanding failures ────────────────────────────
  it("3. Both actions fail: records two failed actions", async () => {
    const auto = await createTestAutomation();

    InstagramService.publishCommentReply = async () => ({
      ok: false,
      error: { message: "Public reply failed", code: 500, category: "API_ERROR" },
    });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: { message: "DM delivery failed", code: 500, category: "API_ERROR", isRetryable: true },
    });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_3",
      text: "test both fail",
      from: { username: "commenter3", id: "user_3" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    const updated = await Automation.findById(auto._id);
    assert.equal(updated.stats.failed, 2, "Both failures must be counted independently (2 total)");
    assert.equal(updated.stats.totalFailedAttempts, 2);
    assert.equal(updated.activityLog[0].publicReply.status, "failed");
    assert.equal(updated.activityLog[0].privateReply.status, "failed");
    assert.ok(updated.activityLog[0].error.includes("[Public Reply]"));
    assert.ok(updated.activityLog[0].error.includes("[DM]"));
  });

  // ── 4. Disabled action: zero failures for that action ─────────────────────────
  it("4. Disabled action: does not count as failure when disabled", async () => {
    const auto = await createTestAutomation({
      publicReply: { enabled: false }, // Public reply disabled
      openingDm: { enabled: true, message: "Only DM" },
    });

    InstagramService.sendPrivateReply = async () => ({
      ok: true,
      messageId: "dm_ok_4",
    });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_4",
      text: "only dm requested",
      from: { username: "commenter4", id: "user_4" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    const updated = await Automation.findById(auto._id);
    assert.equal(updated.stats.failed, 0, "Disabled public reply must not count as failure");
    assert.equal(updated.activityLog[0].publicReply.status, "disabled");
    assert.equal(updated.activityLog[0].privateReply.status, "sent");
  });

  // ── 5. Missing access token: recorded failure with a meaningful reason ────────
  it("5. Missing access token: recorded as failure with meaningful reason", async () => {
    // Clear user's Instagram token
    await User.findByIdAndUpdate(testUser._id, { "instagram.accessToken": null });
    const originalEnvToken = process.env.INSTAGRAM_ACCESS_TOKEN;
    delete process.env.INSTAGRAM_ACCESS_TOKEN;

    const auto = await createTestAutomation();

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_5",
      text: "no token test",
      from: { username: "commenter5", id: "user_5" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    process.env.INSTAGRAM_ACCESS_TOKEN = originalEnvToken;

    const updated = await Automation.findById(auto._id);
    assert.equal(updated.stats.failed, 2, "Missing token on enabled actions must count as failures");
    assert.equal(updated.activityLog[0].publicReply.status, "failed");
    assert.equal(updated.activityLog[0].publicReply.errorCategory, "NO_TOKEN");
    assert.equal(updated.activityLog[0].privateReply.status, "failed");
    assert.equal(updated.activityLog[0].privateReply.errorCategory, "NO_TOKEN");
  });

  // ── 6. Duplicate webhook event: no duplicate delivery or failure record ────────
  it("6. Duplicate webhook event: skips already processed comment without duplicating", async () => {
    const auto = await createTestAutomation();

    let replyCalls = 0;
    InstagramService.publishCommentReply = async () => {
      replyCalls++;
      return { ok: true, replyId: "rep_1" };
    };
    InstagramService.sendPrivateReply = async () => ({
      ok: true,
      messageId: "dm_1",
    });

    const commentPayload = {
      id: "comment_dedup_test",
      text: "dedup test",
      from: { username: "dedup_user", id: "user_d" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    };

    // First arrival
    await AutomationEngine.handleIncomingComment(commentPayload);
    // Duplicate arrival (redelivered webhook)
    await AutomationEngine.handleIncomingComment(commentPayload);

    const updated = await Automation.findById(auto._id);
    assert.equal(replyCalls, 1, "Instagram API should be called only once");
    assert.equal(updated.activityLog.length, 1, "Only one activity record should exist");
    assert.equal(updated.stats.commentsReceived, 1, "Comments counter should only increment once");
  });

  // ── 7. Successful DM retry: failure resolved and historical attempt retained ─
  it("7. Successful DM retry: resolves failure and decrements outstanding count while retaining history", async () => {
    const auto = await createTestAutomation();

    // Initial delivery: DM fails
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_7" });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: { message: "Temporary network timeout", category: "NETWORK_ERROR", isRetryable: true },
    });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_7",
      text: "retry me",
      from: { username: "user7", id: "u7" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    let state = await Automation.findById(auto._id);
    assert.equal(state.stats.failed, 1, "Outstanding failure before retry");
    assert.equal(state.stats.dmsSent, 0);

    const entryId = state.activityLog[0]._id.toString();

    // Now mock successful retry
    InstagramService.sendPrivateReply = async () => ({
      ok: true,
      messageId: "dm_retried_success",
    });

    const res = await makeRequest("POST", `/api/activity/${entryId}/retry-dm`, testUserToken);
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.equal(res.body.activity.privateReplySent, true);
    assert.equal(res.body.activity.privateReplyStatus, "sent");

    // Verify DB stats
    state = await Automation.findById(auto._id);
    assert.equal(state.stats.failed, 0, "Outstanding failure must be cleared on successful retry");
    assert.equal(state.stats.dmsSent, 1, "dmsSent counter must increment");
    assert.equal(state.stats.totalFailedAttempts, 1, "Historical failed attempt must be retained");
    assert.equal(state.activityLog[0].privateReply.attempts, 2, "Attempts count must track total attempts");
  });

  // ── 8. Failed DM retry: attempt history updated without duplicate records ────
  it("8. Failed DM retry: updates attempt history without duplicate records or double-incrementing outstanding failures", async () => {
    const auto = await createTestAutomation();

    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "r8" });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: { message: "Connection refused", category: "NETWORK_ERROR", isRetryable: true },
    });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_8",
      text: "retry fail test",
      from: { username: "user8", id: "u8" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    let state = await Automation.findById(auto._id);
    const entryId = state.activityLog[0]._id.toString();

    // Retry fails again
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: { message: "Still connection refused", category: "NETWORK_ERROR", isRetryable: true },
    });

    const res = await makeRequest("POST", `/api/activity/${entryId}/retry-dm`, testUserToken);
    assert.equal(res.status, 400);

    state = await Automation.findById(auto._id);
    assert.equal(state.activityLog.length, 1, "Must not create duplicate activity records");
    assert.equal(state.stats.failed, 1, "Outstanding failure count must remain 1 (not double-counted)");
    assert.equal(state.stats.totalFailedAttempts, 2, "Historical failed attempts must increment to 2");
    assert.equal(state.activityLog[0].privateReply.attempts, 2);
  });

  // ── 9. Two simultaneous retry requests: concurrency lock prevents double-send ─
  it("9. Simultaneous retry requests: lock prevents concurrent duplicate sends", async () => {
    const auto = await createTestAutomation();

    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "r9" });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: { message: "Fail first", category: "NETWORK_ERROR", isRetryable: true },
    });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_9",
      text: "concurrent retry",
      from: { username: "user9", id: "u9" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    const state = await Automation.findById(auto._id);
    const entryId = state.activityLog[0]._id.toString();

    // Simulate in-progress lock
    state.activityLog[0].privateReply.isProcessing = true;
    state.activityLog[0].privateReply.processingLockAt = new Date();
    await state.save();

    const res = await makeRequest("POST", `/api/activity/${entryId}/retry-dm`, testUserToken);
    assert.equal(res.status, 409, "Should reject with 409 when already in progress");
    assert.ok(res.body.error.includes("currently in progress"));
  });

  // ── 10. Retry of a successfully sent DM: rejected without another send ────────
  it("10. Retry of a successfully sent DM: rejected without sending another message", async () => {
    const auto = await createTestAutomation();

    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "r10" });
    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "m10" });

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_10",
      text: "already sent",
      from: { username: "user10", id: "u10" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    const state = await Automation.findById(auto._id);
    const entryId = state.activityLog[0]._id.toString();

    let sendCalled = false;
    InstagramService.sendPrivateReply = async () => {
      sendCalled = true;
      return { ok: true };
    };

    const res = await makeRequest("POST", `/api/activity/${entryId}/retry-dm`, testUserToken);
    assert.equal(res.status, 409, "Should reject with 409 when DM is already sent");
    assert.equal(sendCalled, false, "Should never call Meta API when already sent");
  });

  // ── 11. Expired comment window: retry blocked ─────────────────────────────────
  it("11. Expired comment window (>7 days): retry blocked per Meta policy", async () => {
    const auto = await createTestAutomation();

    // 8 days ago
    const oldTimestamp = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000);

    auto.activityLog.push({
      _id: new mongoose.Types.ObjectId(),
      commentId: "comment_old_11",
      commentTimestamp: oldTimestamp,
      timestamp: oldTimestamp,
      username: "old_user",
      text: "old comment",
      publicReply: { sent: true, status: "sent" },
      privateReply: {
        sent: false,
        status: "failed",
        attempts: 1,
        retryEligible: true,
      },
    });
    auto.stats.failed = 1;
    await auto.save();

    const entryId = auto.activityLog[0]._id.toString();

    const res = await makeRequest("POST", `/api/activity/${entryId}/retry-dm`, testUserToken);
    assert.equal(res.status, 400, "Should block retry for comment > 7 days old");
    assert.ok(res.body.error.includes("7 days"));

    const updated = await Automation.findById(auto._id);
    assert.equal(updated.activityLog[0].privateReply.retryEligible, false);
  });

  // ── 12. Missing permissions or permanent Meta error: retry blocked ────────────
  it("12. Action block or permanent Meta error: retry blocked safely", async () => {
    const auto = await createTestAutomation();

    auto.activityLog.push({
      _id: new mongoose.Types.ObjectId(),
      commentId: "comment_blocked_12",
      commentTimestamp: new Date(),
      username: "blocked_user",
      text: "action block test",
      publicReply: { sent: false, status: "failed" },
      privateReply: {
        sent: false,
        status: "failed",
        errorCategory: "ACTION_BLOCKED",
        retryEligible: false,
      },
    });
    await auto.save();

    const entryId = auto.activityLog[0]._id.toString();

    const res = await makeRequest("POST", `/api/activity/${entryId}/retry-dm`, testUserToken);
    assert.equal(res.status, 400);
    assert.ok(res.body.error.includes("action blocked"));
  });

  // ── 13. Rate-limit response: classified correctly and handled safely ──────────
  it("13. Rate-limit response: classified as RATE_LIMIT and flagged retryable", () => {
    const parsed = InstagramService.parseMetaError({
      error: { code: 4, message: "Application request limit reached" },
    });
    assert.equal(parsed.category, "RATE_LIMIT");
    assert.equal(parsed.isRetryable, true);
    assert.ok(parsed.message.includes("rate limit"));
  });

  // ── 14. Ambiguous timeout: safe error classification without duplicate send ───
  it("14. Ambiguous network timeout: classified as NETWORK_ERROR without duplicate fallback send", async () => {
    const originalFetch = global.fetch;

    let fetchCount = 0;
    global.fetch = async () => {
      fetchCount++;
      throw new Error("ETIMEDOUT connection timed out");
    };

    const res = await InstagramService.sendPrivateReply(
      "c14",
      "test message",
      "token14",
      "Button",
      "https://example.com"
    );

    global.fetch = originalFetch;

    assert.equal(res.ok, false);
    assert.equal(res.error.category, "NETWORK_ERROR");
    assert.equal(res.error.isRetryable, true);
    // Button template timed out; direct text fallback must NOT have been called with another request
    assert.equal(fetchCount, 1, "Should not make a second blind duplicate call on timeout");
  });

  // ── 15. User attempts to retry another user's activity: rejected with 403 ─────
  it("15. User attempts to retry another user's activity: rejected with 403", async () => {
    // Activity created under otherUser
    const otherAuto = await Automation.create({
      userId: otherUser._id,
      igUserId: "other_ig_user",
      mediaId: "other_media",
      name: "Other Auto",
      status: "active",
      openingDm: { enabled: true, message: "Hello" },
      activityLog: [
        {
          _id: new mongoose.Types.ObjectId(),
          commentId: "other_comment_15",
          commentTimestamp: new Date(),
          username: "someone",
          privateReply: { sent: false, status: "failed", attempts: 1, retryEligible: true },
        },
      ],
    });

    const otherActivityId = otherAuto.activityLog[0]._id.toString();

    // testUser tries to retry otherUser's activity
    const res = await makeRequest("POST", `/api/activity/${otherActivityId}/retry-dm`, testUserToken);
    assert.equal(res.status, 403, "Must return 403 Forbidden for unauthorized access");
  });

  // ── 16. Dry-run mode: no real delivery and no false production delivery metrics
  it("16. Dry-run mode: skips actions with DRY_RUN status and zero failed metrics", async () => {
    process.env.DRY_RUN = "true";
    const auto = await createTestAutomation();

    let realApiCalled = false;
    InstagramService.publishCommentReply = async () => { realApiCalled = true; };
    InstagramService.sendPrivateReply = async () => { realApiCalled = true; };

    await AutomationEngine.handleIncomingComment({
      id: "comment_test_16",
      text: "dry run simulation",
      from: { username: "sim_user", id: "u16" },
      media: { id: "media_1001" },
      timestamp: new Date().toISOString(),
    });

    process.env.DRY_RUN = "false";

    const updated = await Automation.findById(auto._id);
    assert.equal(realApiCalled, false, "Must not call Instagram API in dry-run mode");
    assert.equal(updated.stats.failed, 0, "Dry-run simulations must not increment failed metric");
    assert.equal(updated.stats.repliesSent, 0);
    assert.equal(updated.stats.dmsSent, 0);
    assert.equal(updated.activityLog[0].publicReply.status, "skipped");
    assert.equal(updated.activityLog[0].privateReply.status, "skipped");
  });

  // ── 17. Activity summary: counts match authoritative action statuses ─────────
  it("17. Activity summary: counts match authoritative action statuses and reconcile accurately", async () => {
    const auto = await createTestAutomation();

    auto.activityLog = [
      {
        _id: new mongoose.Types.ObjectId(),
        commentId: "c1",
        username: "u1",
        publicReply: { sent: true, status: "sent" },
        privateReply: { sent: false, status: "failed" }, // 1 unresolved failure
      },
      {
        _id: new mongoose.Types.ObjectId(),
        commentId: "c2",
        username: "u2",
        publicReply: { sent: false, status: "failed" }, // 1 unresolved failure
        privateReply: { sent: true, status: "sent" },
      },
      {
        _id: new mongoose.Types.ObjectId(),
        commentId: "c3",
        username: "u3",
        publicReply: { sent: false, status: "skipped" }, // skipped, not failure
        privateReply: { sent: false, status: "disabled" }, // disabled, not failure
      },
    ];
    auto.stats.commentsReceived = 3;
    auto.stats.repliesSent = 1;
    auto.stats.dmsSent = 1;
    auto.stats.failed = 99; // Corrupted / stale counter
    await auto.save();

    const res = await makeRequest("GET", "/api/activity/summary", testUserToken);
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);

    const summary = res.body.summary;
    assert.equal(summary.failedActions, 2, "Authoritative unresolved failures must equal 2");
    assert.equal(summary.commentsReceived, 3);
    assert.equal(summary.repliesSent, 1);
    assert.equal(summary.dmsSent, 1);

    // Verify automation stats were reconciled in database
    const reconciled = await Automation.findById(auto._id);
    assert.equal(reconciled.stats.failed, 2, "Stale counter must be reconciled with authoritative records");
  });

  // ── 18. POST /api/activity/retry-all-failed: bulk resend eligible actions ─────
  it("18. Bulk resend: retries all eligible failed actions safely and updates counters", async () => {
    const auto = await createTestAutomation();

    auto.activityLog = [
      {
        _id: new mongoose.Types.ObjectId(),
        commentId: "bulk_retry_1",
        commentTimestamp: new Date(),
        username: "user_bulk_1",
        publicReply: { sent: true, status: "sent" },
        privateReply: { sent: false, status: "failed", attempts: 1, retryEligible: true, message: "Hello 1" },
      },
      {
        _id: new mongoose.Types.ObjectId(),
        commentId: "bulk_retry_2",
        commentTimestamp: new Date(),
        username: "user_bulk_2",
        publicReply: { sent: true, status: "sent" },
        privateReply: { sent: false, status: "failed", attempts: 1, retryEligible: true, message: "Hello 2" },
      },
      {
        _id: new mongoose.Types.ObjectId(),
        commentId: "bulk_retry_expired",
        commentTimestamp: new Date(Date.now() - 10 * 24 * 60 * 60 * 1000), // 10 days old
        username: "user_bulk_expired",
        publicReply: { sent: true, status: "sent" },
        privateReply: { sent: false, status: "failed", attempts: 1, retryEligible: false, retryReason: "Expired" },
      },
    ];
    auto.stats.commentsReceived = 3;
    auto.stats.repliesSent = 2;
    auto.stats.dmsSent = 0;
    auto.stats.failed = 3;
    await auto.save();

    let sentComments = [];
    InstagramService.sendPrivateReply = async (commentId) => {
      sentComments.push(commentId);
      return { ok: true, messageId: `msg_${commentId}` };
    };

    const res = await makeRequest("POST", "/api/activity/retry-all-failed", testUserToken);
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.equal(res.body.retriedCount, 2, "Should attempt 2 eligible entries");
    assert.equal(res.body.successCount, 2, "Both eligible entries should succeed");
    assert.equal(sentComments.length, 2);
    assert.deepEqual(sentComments, ["bulk_retry_1", "bulk_retry_2"]);

    const updated = await Automation.findById(auto._id);
    assert.equal(updated.stats.dmsSent, 2);
    assert.equal(updated.stats.failed, 1, "Only expired failure should remain");
    assert.equal(updated.activityLog[0].privateReply.status, "sent");
    assert.equal(updated.activityLog[1].privateReply.status, "sent");
    assert.equal(updated.activityLog[2].privateReply.status, "failed");
  });

  // ── Helper to execute requests against the Express app ───────────────────────
  function makeRequest(method, path, token, body = {}) {
    return new Promise((resolve, reject) => {
      const http = require("http");
      const server = http.createServer(app);
      server.listen(0, () => {
        const port = server.address().port;
        const reqOptions = {
          host: "127.0.0.1",
          port,
          method,
          path,
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
        };

        const clientReq = http.request(reqOptions, (clientRes) => {
          let data = "";
          clientRes.on("data", (chunk) => (data += chunk));
          clientRes.on("end", () => {
            server.close();
            try {
              resolve({
                status: clientRes.statusCode,
                body: JSON.parse(data),
              });
            } catch (_) {
              resolve({
                status: clientRes.statusCode,
                body: data,
              });
            }
          });
        });

        clientReq.on("error", (err) => {
          server.close();
          reject(err);
        });

        if (method !== "GET") {
          clientReq.write(JSON.stringify(body));
        }
        clientReq.end();
      });
    });
  }
});
