const express = require("express");
const { Pool } = require("pg");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");
const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");

const app = express();
app.use(express.json());

// PGHOST, PGUSER, PGPASSWORD, PGDATABASE, PGSSLMODE come from environment (Secrets Manager in AWS)
const pool = new Pool();
const s3 = new S3Client({ requestChecksumCalculation: "WHEN_REQUIRED" });
const sqs = new SQSClient({});

// DEMO ONLY: in production the ALB/Cognito (or aws-jwt-verify) supplies the verified user id.
const user = (req) => req.headers["x-user-id"] || "demo-student";

app.get("/api/health", async (_req, res) => {
  try { await pool.query("SELECT 1"); res.send("ok"); }
  catch (e) { console.error("health: db error:", e.message); res.status(503).send("db unavailable"); }
});

// Questions (never returns the correct answer)
app.get("/api/exams/:id", async (req, res) => {
  const q = await pool.query(
    "SELECT id, text, options FROM questions WHERE exam_id=$1 ORDER BY id", [req.params.id]);
  const saved = await pool.query(
    "SELECT question_id, answer FROM answers WHERE student_id=$1 AND exam_id=$2",
    [user(req), req.params.id]);
  res.json({ examId: req.params.id, questions: q.rows, saved: saved.rows });
});

// Autosave (frontend calls this every 30 s)
app.put("/api/exams/:id/answers", async (req, res) => {
  const entries = Object.entries(req.body || {});
  for (const [qid, ans] of entries) {
    await pool.query(
      `INSERT INTO answers (student_id, exam_id, question_id, answer)
       VALUES ($1,$2,$3,$4)
       ON CONFLICT (student_id, exam_id, question_id)
       DO UPDATE SET answer=EXCLUDED.answer, saved_at=now()`,
      [user(req), req.params.id, qid, String(ans)]);
  }
  res.json({ saved: entries.length, at: new Date().toISOString() });
});

// Submit exam -> SQS -> marking Lambda
app.post("/api/exams/:id/submit", async (req, res) => {
  await sqs.send(new SendMessageCommand({
    QueueUrl: process.env.MARKING_QUEUE_URL,
    MessageBody: JSON.stringify({ studentId: user(req), examId: Number(req.params.id) })
  }));
  res.json({ queued: true });
});

app.get("/api/results/:id", async (req, res) => {
  const r = await pool.query(
    "SELECT score FROM results WHERE student_id=$1 AND exam_id=$2", [user(req), req.params.id]);
  res.json(r.rows[0] || { score: null });
});

// Presigned upload URL: the 50 MB file goes straight to S3, not through the API
app.get("/api/uploads/presign", async (req, res) => {
  const key = `submissions/${user(req)}/${Date.now()}.zip`;
  const url = await getSignedUrl(
    s3,
    new PutObjectCommand({
      Bucket: process.env.UPLOAD_BUCKET,
      Key: key,

    }),
    { expiresIn: 300 });
  await pool.query("INSERT INTO submissions (student_id, s3_key) VALUES ($1,$2)", [user(req), key]);
  res.json({ url, key });
});

// Local development only: serve the frontend from the same origin
if (process.env.FRONTEND_DIR) app.use(express.static(process.env.FRONTEND_DIR));

app.use((err, _req, res, _next) => { console.error(err); res.status(500).json({ error: "server error" }); });
app.listen(8080, () => console.log("API listening on 8080"));
