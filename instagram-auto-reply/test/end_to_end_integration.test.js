const { describe, it, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const mongoose = require("mongoose");
const express = require("express");
const jwt = require("jsonwebtoken");
const http = require("http");

process.env.JWT_SECRET = "test_jwt_secret_e2e_1234";
process.env.DRY_RUN = "false";

const User = require("../models/User");
const ActionLedger = require("../models/ActionLedger");
const Automation = require("../models/Automation");
const BackfillJob = require("../models/BackfillJob");
const ActionLedgerService = require("../services/actionLedgerService");
const AutomationEngine = require("../services/automationEngine");
const InstagramService = require("../services/instagramService");
const { ANTI_SPAM_RULES } = require("../config/instagramRules");
const activityRouter = require("../routes/activity");

const TEST_DB_URI = process.env.TEST_DB_URI || "mongodb://127.0.0.1:27017/instauto_test";

describe("End-to-End Integration Tests (Route -> Engine -> Ledger -> Meta Mock -> Persistence -> Response)", () => {
  let app;
  let mockAutomation;
  let testUser;
  let testToken;
  const originalSendPrivateReply = InstagramService.sendPrivateReply;
  const originalPublishCommentReply = InstagramService.publishCommentReply;

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

        const clientReq = http.request(
          {
            host: "127.0.0.1",
            port,
            method,
            path,
            headers: reqHeaders,
          },
          (res) => {
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
          }
        );

        clientReq.on("error", (err) => {
          server.close();
          reject(err);
        });

        if (payload) clientReq.write(payload);
        clientReq.end();
      });
    });
  }

  before(async () => {
    if (mongoose.connection.readyState === 0) {
      await mongoose.connect(TEST_DB_URI);
    }

    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = false;

    app = express();
    app.use(express.json());
    app.use("/api/activity", activityRouter);
  });

  after(async () => {
    InstagramService.sendPrivateReply = originalSendPrivateReply;
    InstagramService.publishCommentReply = originalPublishCommentReply;
    ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY = true;

    await User.deleteMany({ email: { $regex: /@e2e-test\.local$/ } });
    await ActionLedger.deleteMany({});
    await Automation.deleteMany({});
    await BackfillJob.deleteMany({});
    await mongoose.disconnect();
  });

  beforeEach(async () => {
    InstagramService.sendPrivateReply = originalSendPrivateReply;
    InstagramService.publishCommentReply = originalPublishCommentReply;

    await User.deleteMany({ email: { $regex: /@e2e-test\.local$/ } });
    await ActionLedger.deleteMany({});
    await Automation.deleteMany({});
    await BackfillJob.deleteMany({});

    testUser = await User.create({
      name: "E2E Tester",
      email: `tester_${Date.now()}_${Math.random()}@e2e-test.local`,
      password: "password123",
      instagram: {
        userId: "ig_e2e_user_123",
        id: "ig_e2e_user_123",
        username: "e2e_account",
        accessToken: "valid_e2e_access_token",
      },
    });

    testToken = jwt.sign({ id: testUser._id }, process.env.JWT_SECRET);

    mockAutomation = await Automation.create({
      userId: testUser._id,
      igUserId: "ig_e2e_user_123",
      mediaId: "media_e2e_1",
      name: "E2E Integration Automation",
      status: "active",
      trigger: { matchType: "keywords", keywords: ["price", "buy"], wholeWord: false },
      publicReply: { enabled: true, messages: ["Thanks for reaching out!"] },
      openingDm: { enabled: true, message: "Here is your VIP discount code!", buttonEnabled: false },
      activityLog: [],
      stats: { totalComments: 0, repliesSent: 0, dmsSent: 0, failed: 0 },
    });
  });

  it("Integration 1: Confirmed successful delivery end-to-end", async () => {
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "reply_meta_1" });
    InstagramService.sendPrivateReply = async () => ({ ok: true, messageId: "mid.meta_confirmed_e2e_123" });

    const commentEvent = {
      id: "comm_e2e_success_1",
      media: { id: "media_e2e_1" },
      from: { username: "happy_customer", id: "ig_cust_1" },
      text: "What is the price?",
      timestamp: new Date().toISOString(),
    };

    await AutomationEngine.handleIncomingComment(commentEvent);

    const res = await makeRequest("GET", `/api/activity?automationId=${mockAutomation._id}`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.ok(Array.isArray(res.body.activity));
    const entry = res.body.activity.find((a) => a.commentId === commentEvent.id);
    assert.ok(entry);
    assert.equal(entry.status, "sent");
    assert.equal(entry.messageId, "mid.meta_confirmed_e2e_123");
    assert.equal(entry.reconciliationRequired, false);
    assert.equal(entry.retryEligible, false);
  });

  it("Integration 2: Confirmed previous delivery (reconciliation)", async () => {
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "reply_meta_2" });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: {
        message: "(#100) You have already replied to this comment.",
        code: 100,
        subcode: 2018002,
        category: "ALREADY_REPLIED",
      },
    });

    const commentEvent = {
      id: "comm_e2e_reconcile_1",
      media: { id: "media_e2e_1" },
      from: { username: "prior_buyer", id: "ig_cust_2" },
      text: "Can I buy again?",
      timestamp: new Date().toISOString(),
    };

    await AutomationEngine.handleIncomingComment(commentEvent);

    const res = await makeRequest("GET", `/api/activity?automationId=${mockAutomation._id}`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(res.status, 200);

    const entry = res.body.activity.find((a) => a.commentId === commentEvent.id);
    assert.ok(entry);
    assert.equal(entry.status, "sent");
    assert.equal(entry.retryEligible, false);

    const ledger = await ActionLedger.findOne({
      commentId: commentEvent.id,
      actionType: "dm",
    });
    assert.equal(ledger.status, "sent");
    assert.equal(ledger.reconciliationReason, "ALREADY_REPLIED_META");
  });

  it("Integration 3: Permanent ineligibility (older than 7 days)", async () => {
    let dmAttempted = false;
    InstagramService.publishCommentReply = async () => ({ ok: true, replyId: "reply_meta_old_1" });
    InstagramService.sendPrivateReply = async () => {
      dmAttempted = true;
      return { ok: true };
    };

    const commentEvent = {
      id: "comm_e2e_old_1",
      media: { id: "media_e2e_1" },
      from: { username: "vintage_user", id: "ig_cust_3" },
      text: "What is the price?",
      timestamp: new Date(Date.now() - 10 * 24 * 3600 * 1000).toISOString(),
    };

    await AutomationEngine.handleIncomingComment(commentEvent);

    assert.equal(dmAttempted, false, "Must not attempt DM for >7 days comment");

    const res = await makeRequest("GET", `/api/activity?automationId=${mockAutomation._id}`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(res.status, 200);

    const entry = res.body.activity.find((a) => a.commentId === commentEvent.id);
    assert.ok(entry);
    assert.equal(entry.privateReplyStatus, "skipped");
    assert.equal(entry.retryEligible, false);
  });

  it("Integration 4: Definitive failure records non-sent status", async () => {
    InstagramService.publishCommentReply = async () => ({ ok: true });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: {
        message: "User cannot receive direct messages.",
        code: 100,
      },
    });

    const commentEvent = {
      id: "comm_e2e_fail_1",
      media: { id: "media_e2e_1" },
      from: { username: "restricted_account", id: "ig_cust_4" },
      text: "price please",
      timestamp: new Date().toISOString(),
    };

    await AutomationEngine.handleIncomingComment(commentEvent);

    const res = await makeRequest("GET", `/api/activity?automationId=${mockAutomation._id}`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(res.status, 200);

    const entry = res.body.activity.find((a) => a.commentId === commentEvent.id);
    assert.ok(entry);
    assert.equal(entry.privateReplyStatus, "failed");
    assert.notEqual(entry.status, "sent");
  });

  it("Integration 5: Ambiguous timeout records reconciliation_required and blocks unsafe retry", async () => {
    InstagramService.publishCommentReply = async () => ({ ok: true });
    InstagramService.sendPrivateReply = async () => ({
      ok: false,
      error: {
        message: "ETIMEDOUT: Connection timed out",
        category: "AMBIGUOUS_TIMEOUT",
        isTimeout: true,
        isAmbiguous: true,
      },
    });

    const commentEvent = {
      id: "comm_e2e_timeout_1",
      media: { id: "media_e2e_1" },
      from: { username: "timeout_user", id: "ig_cust_5" },
      text: "price info",
      timestamp: new Date().toISOString(),
    };

    await AutomationEngine.handleIncomingComment(commentEvent);

    const res = await makeRequest("GET", `/api/activity?automationId=${mockAutomation._id}`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(res.status, 200);

    const entry = res.body.activity.find((a) => a.commentId === commentEvent.id);
    assert.ok(entry);
    assert.equal(entry.reconciliationRequired, true);
    assert.notEqual(entry.status, "sent");

    const targetId = entry.actionId || entry.id || commentEvent.id;
    const retryRes = await makeRequest("POST", `/api/activity/${targetId}/retry-dm`, {
      Authorization: `Bearer ${testToken}`,
    });
    assert.equal(retryRes.status, 400);
    assert.equal(retryRes.body.ok, false);
    assert.match(retryRes.body.error, /reconciliation/i);
  });

  it("Integration 6: Concurrent duplicate requests claim only once", async () => {
    let dmCalls = 0;
    InstagramService.publishCommentReply = async () => ({ ok: true });
    InstagramService.sendPrivateReply = async () => {
      dmCalls++;
      await new Promise((r) => setTimeout(r, 20));
      return { ok: true, messageId: `mid.conc_${dmCalls}` };
    };

    const commentEvent = {
      id: "comm_e2e_concurrent_1",
      media: { id: "media_e2e_1" },
      from: { username: "twin_commenter", id: "ig_cust_6" },
      text: "buy now",
      timestamp: new Date().toISOString(),
    };

    await Promise.all([
      AutomationEngine.handleIncomingComment(commentEvent),
      AutomationEngine.handleIncomingComment(commentEvent),
    ]);

    assert.equal(dmCalls, 1, "Exactly one worker should execute sendPrivateReply");
  });

  it("Integration 7: Restart and recovery of stale processing lease", async () => {
    const commentId = "comm_e2e_crash_1";
    const igUserId = "ig_e2e_user_123";
    const mediaId = "media_e2e_1";
    const actionKey = ActionLedgerService.buildActionKey({
      igUserId,
      mediaId,
      commentId,
      actionType: "dm",
    });

    await ActionLedger.create({
      actionKey,
      igUserId,
      mediaId,
      commentId,
      actionType: "dm",
      status: "processing",
      leaseExpiresAt: new Date(Date.now() - 60 * 1000), // Expired 1 minute ago
      claimToken: "crashed_claim_token_999",
    });

    const claim = await ActionLedgerService.claimAction({
      igUserId,
      mediaId,
      commentId,
      actionType: "dm",
      source: "recovery",
    });

    assert.equal(claim.claimed, true);
    assert.equal(claim.isRecovery, true);
    assert.ok(claim.record);

    await ActionLedgerService.finalizeAction({
      actionKey: claim.record.actionKey,
      claimToken: claim.claimToken,
      result: { ok: true, messageId: "mid.recovered_123" },
    });

    const recovered = await ActionLedger.findById(claim.record._id);
    assert.equal(recovered.status, "sent");
    assert.equal(recovered.messageId, "mid.recovered_123");
  });
});
