const { describe, it, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const mongoose = require("mongoose");
const express = require("express");
const jwt = require("jsonwebtoken");
const http = require("http");

process.env.JWT_SECRET = "test_jwt_secret_12345";
process.env.DRY_RUN = "false";
process.env.BOT_USERNAME = "bot_account";

const User = require("../models/User");
const Automation = require("../models/Automation");
const BackfillJob = require("../models/BackfillJob");
const ActionLedger = require("../models/ActionLedger");
const ActionLedgerService = require("../services/actionLedgerService");
const ReconciliationService = require("../services/reconciliationService");
const BackfillService = require("../services/backfillService");
const AutomationEngine = require("../services/automationEngine");
const InstagramService = require("../services/instagramService");
const automationsRouter = require("../routes/automations");
const activityRouter = require("../routes/activity");

const TEST_DB_URI = process.env.TEST_MONGO_URI || "mongodb://127.0.0.1:27017/instauto_test";

describe("Action Ledger, Strong Deduplication, and Ineligibility Suite", () => {
  let originalPublishReply;
  let originalSendPrivateReply;
  let originalFetchComments;
  let testUser;
  let testUserToken;
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
    app.use(express.json());
    app.use("/api/automations", automationsRouter);
    app.use("/api/activity", activityRouter);
  });

  after(async () => {
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;
    InstagramService.fetchComments = originalFetchComments;

    const { ANTI_SPAM_RULES } = require("../config/instagramRules");
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = true;

    await User.deleteMany({ email: { $regex: /@ledger-test\.local$/ } });
    await Automation.deleteMany({ igUserId: "test_ledger_ig" });
    await BackfillJob.deleteMany({});
    await ActionLedger.deleteMany({});
    await mongoose.disconnect();
  });

  beforeEach(async () => {
    InstagramService.publishCommentReply = originalPublishReply;
    InstagramService.sendPrivateReply = originalSendPrivateReply;
    InstagramService.fetchComments = originalFetchComments;

    await User.deleteMany({ email: { $regex: /@ledger-test\.local$/ } });
    await Automation.deleteMany({ igUserId: "test_ledger_ig" });
    await BackfillJob.deleteMany({});
    await ActionLedger.deleteMany({});

    testUser = await User.create({
      name: "Ledger Tester",
      email: `tester_${Date.now()}@ledger-test.local`,
      password: "password123",
      instagram: {
        userId: "test_ledger_ig",
        id: "test_ledger_ig",
        username: "tester_ig",
        accessToken: "valid_test_token_ledger",
      },
    });

    testUserToken = jwt.sign({ id: testUser._id }, process.env.JWT_SECRET);
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

  function makeRequest(method, path, token, body = {}) {
    return new Promise((resolve, reject) => {
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

  async function createTestAutomation(mediaId = "media_post_200", overrides = {}) {
    return await Automation.create({
      userId: testUser._id,
      igUserId: "test_ledger_ig",
      mediaId,
      name: "Deduplication Test Reel",
      status: "active",
      trigger: {
        matchType: "any",
        keywords: ["link", "price"],
      },
      publicReply: {
        enabled: true,
        messages: ["Thanks for commenting @{username}!"],
      },
      openingDm: {
        enabled: true,
        message: "Here is your exclusive link!",
        buttonText: "Check Out",
        link: "https://example.com/item",
      },
      stats: { totalComments: 0, repliesSent: 0, dmsSent: 0, failedActions: 0 },
      activityLog: [],
      ...overrides,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION A: DUPLICATE DM PREVENTION & SINGLE-DM-PER-USER
  // ═══════════════════════════════════════════════════════════════════════════
  describe("A. Duplicate Send Prevention", () => {
    it("A1. First historical backfill sends DM; re-running on new job does NOT send again", async () => {
      const auto = await createTestAutomation("media_201");
      let dmCalls = 0;
      let replyCalls = 0;

      InstagramService.fetchComments = async () => ({
        ok: true,
        comments: [
          { id: "c_201_1", text: "link please", username: "alice", from: { id: "u_alice", username: "alice" }, timestamp: new Date().toISOString() },
        ],
      });
      InstagramService.publishCommentReply = async () => { replyCalls++; return { ok: true, replyId: "rep_1" }; };
      InstagramService.sendPrivateReply = async () => { dmCalls++; return { ok: true, messageId: "msg_1" }; };

      // Job 1
      const startRes1 = await BackfillService.startJob(testUser._id, auto._id);
      await waitForJob(startRes1.job._id);

      assert.equal(dmCalls, 1, "First job must send exactly 1 DM");
      assert.equal(replyCalls, 1, "First job must send exactly 1 Public Reply");

      // Verify ActionLedger records
      const dmRecord = await ActionLedger.findOne({ commentId: "c_201_1", actionType: "dm" });
      assert.ok(dmRecord);
      assert.equal(dmRecord.status, "sent");
      assert.equal(dmRecord.messageId, "msg_1");

      // Job 2 on the SAME Reel: since all comments were already processed, starting a new job refuses to duplicate
      await assert.rejects(
        () => BackfillService.startJob(testUser._id, auto._id),
        /No eligible comments found/
      );

      assert.equal(dmCalls, 1, "Second job MUST NOT send a second DM to alice");
      assert.equal(replyCalls, 1, "Second job MUST NOT post a second public reply");
    });

    it("A2. Multiple comments from same user on same post: sends DM ONCE, subsequent comments skipped", async () => {
      const auto = await createTestAutomation("media_202");
      let dmCalls = 0;
      let replyCalls = 0;

      InstagramService.fetchComments = async () => ({
        ok: true,
        comments: [
          { id: "c_202_1", text: "link", username: "bob", from: { id: "u_bob", username: "bob" }, timestamp: new Date().toISOString() },
          { id: "c_202_2", text: "link again", username: "bob", from: { id: "u_bob", username: "bob" }, timestamp: new Date().toISOString() },
          { id: "c_202_3", text: "still waiting for link", username: "bob", from: { id: "u_bob", username: "bob" }, timestamp: new Date().toISOString() },
        ],
      });
      InstagramService.publishCommentReply = async () => { replyCalls++; return { ok: true, replyId: `rep_${replyCalls}` }; };
      InstagramService.sendPrivateReply = async () => { dmCalls++; return { ok: true, messageId: `msg_${dmCalls}` }; };

      const startRes = await BackfillService.startJob(testUser._id, auto._id);
      const job = await waitForJob(startRes.job._id);

      assert.equal(dmCalls, 1, "Single-DM-per-user-per-post: Exactly 1 DM must be sent to bob across all comments");
      assert.equal(replyCalls, 3, "Public replies remain independent: each distinct comment receives public reply");

      assert.equal(job.actions[0].privateReply.status, "sent");
      assert.equal(job.actions[1].privateReply.status, "skipped");
      assert.equal(job.actions[1].privateReply.skipReason, "ALREADY_SENT_TO_USER");
      assert.equal(job.actions[2].privateReply.status, "skipped");
      assert.equal(job.actions[2].privateReply.skipReason, "ALREADY_SENT_TO_USER");
    });

    it("A3. Repeated webhook event does not resend an already-delivered DM", async () => {
      const auto = await createTestAutomation("media_203");
      let dmCalls = 0;

      InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_wh_1" });
      InstagramService.sendPrivateReply = async () => { dmCalls++; return { ok: true, messageId: `msg_wh_${dmCalls}` }; };

      // Webhook event 1
      await AutomationEngine.handleIncomingComment({
        id: "c_wh_1",
        text: "send link",
        from: { username: "carol", id: "u_carol" },
        media: { id: "media_203" },
        timestamp: new Date().toISOString(),
      });

      assert.equal(dmCalls, 1, "First webhook must send DM");

      // Webhook event 2 (same comment delivered again by Meta)
      await AutomationEngine.handleIncomingComment({
        id: "c_wh_1",
        text: "send link",
        from: { username: "carol", id: "u_carol" },
        media: { id: "media_203" },
        timestamp: new Date().toISOString(),
      });

      assert.equal(dmCalls, 1, "Repeated webhook event must not call sendPrivateReply again");
    });

    it("A4. Manual retry of a successful DM is rejected with 409 and zero Meta API calls", async () => {
      const auto = await createTestAutomation("media_204");
      let dmCalls = 0;

      InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_4" });
      InstagramService.sendPrivateReply = async () => { dmCalls++; return { ok: true, messageId: "msg_4" }; };

      await AutomationEngine.handleIncomingComment({
        id: "c_204_1",
        text: "link",
        from: { username: "dave", id: "u_dave" },
        media: { id: "media_204" },
        timestamp: new Date().toISOString(),
      });

      assert.equal(dmCalls, 1);

      const refreshed = await Automation.findById(auto._id);
      const activityId = refreshed.activityLog[0]._id.toString();

      // Attempt manual retry via HTTP
      const res = await makeRequest("POST", `/api/activity/${activityId}/retry-dm`, testUserToken);

      assert.equal(res.status, 409, "Should reject already delivered DM with 409 Conflict");
      assert.equal(dmCalls, 1, "Meta API must not be called when retrying a successful action");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION B: INELIGIBILITY SKIPPING & META POLICY RESTRICTIONS
  // ═══════════════════════════════════════════════════════════════════════════
  describe("B. Ineligible Actions Handling", () => {
    it("B1. Meta Code 1 (Dev Mode / non-tester) is classified as skipped, NOT technical failure", async () => {
      const auto = await createTestAutomation("media_205");

      InstagramService.fetchComments = async () => ({
        ok: true,
        comments: [
          { id: "c_dev_1", text: "link", username: "non_tester_user", from: { id: "u_dev_1", username: "non_tester_user" }, timestamp: new Date().toISOString() },
        ],
      });
      InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_dev_1" });
      InstagramService.sendPrivateReply = async () => ({
        ok: false,
        error: {
          code: 1,
          message: "Application request limit reached or user is not in instagram testers in development mode",
          category: "DEV_MODE_RESTRICTION",
        },
      });

      const startRes = await BackfillService.startJob(testUser._id, auto._id);
      const job = await waitForJob(startRes.job._id);

      assert.equal(job.actions[0].privateReply.status, "skipped");
      assert.equal(job.actions[0].privateReply.skipReason, "DEV_MODE_RESTRICTION");
      assert.equal(job.actions[0].publicReply.status, "sent", "Eligible public reply succeeds independently of DM ineligibility");
      assert.equal(job.failedCount, 0, "Ineligible actions must NOT increment failedCount");

      // Verify ActionLedger record
      const ledgerEntry = await ActionLedger.findOne({ commentId: "c_dev_1", actionType: "dm" });
      assert.equal(ledgerEntry.status, "skipped");
      assert.equal(ledgerEntry.skipReason, "DEV_MODE_RESTRICTION");
    });

    it("B2. Comment > 7 days old is skipped with WINDOW_CLOSED_7_DAYS before calling Meta API", async () => {
      const auto = await createTestAutomation("media_206");
      let dmCalls = 0;
      let replyCalls = 0;

      const tenDaysAgo = new Date(Date.now() - 10 * 24 * 60 * 60 * 1000).toISOString();
      InstagramService.fetchComments = async () => ({
        ok: true,
        comments: [
          { id: "c_old_1", text: "price please", username: "old_commenter", from: { id: "u_old_1", username: "old_commenter" }, timestamp: tenDaysAgo },
        ],
      });
      InstagramService.publishCommentReply = async () => { replyCalls++; return { ok: true, replyId: "rep_old_1" }; };
      InstagramService.sendPrivateReply = async () => { dmCalls++; return { ok: true, messageId: "msg_old_1" }; };

      const startRes = await BackfillService.startJob(testUser._id, auto._id);
      const job = await waitForJob(startRes.job._id);

      assert.equal(dmCalls, 0, "No Meta send call should be made for >7d comment");
      assert.equal(replyCalls, 1, "Public reply must still be sent (DM ineligibility does not block public reply)");

      assert.equal(job.actions[0].privateReply.status, "skipped");
      assert.equal(job.actions[0].privateReply.skipReason, "WINDOW_CLOSED_7_DAYS");
    });

    it("B3. Window closed 24h (subcode 2534022) is classified as skipped with WINDOW_CLOSED_24H", async () => {
      const auto = await createTestAutomation("media_207");

      InstagramService.fetchComments = async () => ({
        ok: true,
        comments: [
          { id: "c_win_1", text: "link", username: "window_user", from: { id: "u_win_1", username: "window_user" }, timestamp: new Date().toISOString() },
        ],
      });
      InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_win_1" });
      InstagramService.sendPrivateReply = async () => ({
        ok: false,
        error: { code: 10, subcode: 2534022, message: "Message outside of allowed window", category: "POLICY_RESTRICTION" },
      });

      const startRes = await BackfillService.startJob(testUser._id, auto._id);
      const job = await waitForJob(startRes.job._id);

      assert.equal(job.actions[0].privateReply.status, "skipped");
      assert.equal(job.actions[0].privateReply.skipReason, "WINDOW_CLOSED_24H");
      assert.equal(job.failedCount, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION C: ATOMIC CONCURRENCY & LEASE TIMEOUT
  // ═══════════════════════════════════════════════════════════════════════════
  describe("C. Atomic Concurrency and Claim Recovery", () => {
    it("C1. Multiple concurrent workers cannot claim the same action simultaneously", async () => {
      const params = {
        igUserId: "test_ledger_ig",
        mediaId: "media_concurrent_1",
        commentId: "c_conc_1",
        actionType: "dm",
        recipientId: "u_conc_1",
        username: "conc_user",
        automationId: new mongoose.Types.ObjectId(),
        source: "backfill",
      };

      const [claim1, claim2] = await Promise.all([
        ActionLedgerService.claimAction(params),
        ActionLedgerService.claimAction(params),
      ]);

      const claimedCount = (claim1.claimed ? 1 : 0) + (claim2.claimed ? 1 : 0);
      assert.equal(claimedCount, 1, "Exactly one worker must successfully claim the action");

      const rejected = claim1.claimed ? claim2 : claim1;
      assert.equal(rejected.claimed, false);
      assert.equal(rejected.status, "processing");
    });

    it("C2. Expired lease is safely recovered by a subsequent worker", async () => {
      const params = {
        igUserId: "test_ledger_ig",
        mediaId: "media_lease_1",
        commentId: "c_lease_1",
        actionType: "dm",
        recipientId: "u_lease_1",
        username: "lease_user",
        automationId: new mongoose.Types.ObjectId(),
        source: "backfill",
      };

      // Worker 1 claims
      const claim1 = await ActionLedgerService.claimAction(params);
      assert.equal(claim1.claimed, true);

      // Force lease expiration
      await ActionLedger.updateOne(
        { actionKey: claim1.record.actionKey },
        { claimExpiresAt: new Date(Date.now() - 10000) }
      );

      // Worker 2 attempts claim
      const claim2 = await ActionLedgerService.claimAction(params);
      assert.equal(claim2.claimed, true, "Worker 2 must successfully recover expired claim");
      assert.notEqual(claim1.claimToken, claim2.claimToken, "New worker must receive a fresh claim token");
    });

    it("C3. Stale worker cannot overwrite a newer finalized action outcome", async () => {
      const params = {
        igUserId: "test_ledger_ig",
        mediaId: "media_stale_1",
        commentId: "c_stale_1",
        actionType: "dm",
        recipientId: "u_stale_1",
        username: "stale_user",
        automationId: new mongoose.Types.ObjectId(),
        source: "backfill",
      };

      const claim1 = await ActionLedgerService.claimAction(params);

      // Force lease expiration and allow Worker 2 to succeed
      await ActionLedger.updateOne(
        { actionKey: claim1.record.actionKey },
        { claimExpiresAt: new Date(Date.now() - 10000) }
      );

      const claim2 = await ActionLedgerService.claimAction(params);
      await ActionLedgerService.finalizeAction({
        actionKey: claim2.record.actionKey,
        claimToken: claim2.claimToken,
        result: { ok: true, messageId: "msg_worker2_win" },
      });

      // Stale Worker 1 attempts to finalize with its stale claimToken
      const staleFinalize = await ActionLedgerService.finalizeAction({
        actionKey: claim1.record.actionKey,
        claimToken: claim1.claimToken,
        result: { ok: false, error: { message: "stale worker error" } },
      });

      assert.equal(staleFinalize, null, "Stale worker finalize must be rejected (returns null)");

      // Verify database record preserved Worker 2's successful delivery
      const record = await ActionLedger.findOne({ actionKey: claim1.record.actionKey });
      assert.equal(record.status, "sent");
      assert.equal(record.messageId, "msg_worker2_win");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION D: AMBIGUOUS OUTCOMES (NETWORK TIMEOUT)
  // ═══════════════════════════════════════════════════════════════════════════
  describe("D. Ambiguous Delivery Outcomes", () => {
    it("D1. Network timeout marks action as 'unknown' and prevents automatic retries", async () => {
      const auto = await createTestAutomation("media_208");

      InstagramService.fetchComments = async () => ({
        ok: true,
        comments: [
          { id: "c_timeout_1", text: "link please", username: "timeout_user", from: { id: "u_t1", username: "timeout_user" }, timestamp: new Date().toISOString() },
        ],
      });
      InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "rep_t1" });
      InstagramService.sendPrivateReply = async () => ({
        ok: false,
        error: { message: "ETIMEDOUT connection timed out", category: "NETWORK_ERROR", isRetryable: true, isAmbiguous: true },
      });

      const startRes = await BackfillService.startJob(testUser._id, auto._id);
      const job = await waitForJob(startRes.job._id);

      assert.equal(job.actions[0].privateReply.status, "unknown");

      const ledgerEntry = await ActionLedger.findOne({ commentId: "c_timeout_1", actionType: "dm" });
      assert.equal(ledgerEntry.status, "unknown");

      // Running job again on same Reel must NOT retry the ambiguous action automatically
      let sendCalledAgain = false;
      InstagramService.sendPrivateReply = async () => {
        sendCalledAgain = true;
        return { ok: true };
      };

      try {
        const startRes2 = await BackfillService.startJob(testUser._id, auto._id);
        await waitForJob(startRes2.job._id);
      } catch (err) {
        assert.ok(err.message.includes("No eligible comments"));
      }

      assert.equal(sendCalledAgain, false, "Ambiguous delivery must NEVER be automatically resent");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SECTION E: HISTORICAL RECONCILIATION ENGINE
  // ═══════════════════════════════════════════════════════════════════════════
  describe("E. Historical Database Reconciliation", () => {
    it("E1. Reconciles legacy activityLog into ActionLedger idempotently without duplicate records", async () => {
      await Automation.deleteMany({});
      await ActionLedger.deleteMany({});
      const auto = await createTestAutomation("media_legacy_1");

      // Create legacy activityLog entry
      auto.activityLog.push({
        commentId: "c_legacy_100",
        commentTimestamp: new Date(),
        username: "legacy_user",
        recipientId: "u_legacy_100",
        text: "send info",
        publicReply: { sent: true, status: "sent", messageId: "rep_legacy_1" },
        privateReply: { sent: true, status: "sent", messageId: "msg_legacy_1" },
      });
      await auto.save();

      // Run dry-run first
      const dryReport = await ReconciliationService.reconcile({ dryRun: true });
      assert.equal(dryReport.dryRun, true);
      assert.equal(dryReport.reconciledDms, 1);
      assert.equal(dryReport.reconciledPublicReplies, 1);

      // Verify no records inserted in dry-run mode
      const ledgerCountBefore = await ActionLedger.countDocuments();
      assert.equal(ledgerCountBefore, 0, "Dry-run must not insert any database records");

      // Run real migration
      const realReport = await ReconciliationService.reconcile({ dryRun: false });
      assert.equal(realReport.dryRun, false);
      assert.equal(realReport.reconciledDms, 1);
      assert.equal(realReport.reconciledPublicReplies, 1);

      const dmRecord = await ActionLedger.findOne({ commentId: "c_legacy_100", actionType: "dm" });
      assert.ok(dmRecord);
      assert.equal(dmRecord.status, "sent");
      assert.equal(dmRecord.messageId, "msg_legacy_1");

      // Run migration AGAIN to verify idempotency
      const rerunReport = await ReconciliationService.reconcile({ dryRun: false });
      assert.equal(rerunReport.alreadyExistingInLedger, 2, "Second run must skip already reconciled records");
      assert.equal(rerunReport.reconciledDms, 0);

      const finalCount = await ActionLedger.countDocuments();
      assert.equal(finalCount, 2, "Reconciliation must not create duplicate action records");
    });
  });
});
