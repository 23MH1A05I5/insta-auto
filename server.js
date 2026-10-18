
const express = require("express");

const app = express();
const PORT = 3000;

// Log every request that reaches this server
app.use((req, res, next) => {
  console.log(`\n${new Date().toISOString()} ${req.method} ${req.url}`);
  next();
});

app.use(express.json());

// Test route
app.get("/", (req, res) => {
  res.send("Instagram Auto Reply Server is running!");
});

// Meta webhook verification
app.get("/webhook", (req, res) => {
  const mode = req.query["hub.mode"];
  const token = req.query["hub.verify_token"];
  const challenge = req.query["hub.challenge"];

  if (mode === "subscribe" && token === "my_verify_token") {
    console.log("Webhook verification successful");
    return res.status(200).send(challenge);
  }

  console.log("Webhook verification failed");
  return res.sendStatus(403);
});

// Receive Instagram webhook events
app.post("/webhook", (req, res) => {
  console.log("WEBHOOK POST RECEIVED");
  console.log(JSON.stringify(req.body, null, 2));

  return res.sendStatus(200);
});

// Handle unknown routes
app.use((req, res) => {
  res.sendStatus(404);
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
