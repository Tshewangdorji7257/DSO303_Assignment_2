CREATE TABLE IF NOT EXISTS exams (id SERIAL PRIMARY KEY, title TEXT, duration_min INT);
CREATE TABLE IF NOT EXISTS questions (
  id SERIAL PRIMARY KEY, exam_id INT REFERENCES exams(id),
  text TEXT, options JSONB, correct TEXT);
CREATE TABLE IF NOT EXISTS answers (
  student_id TEXT, exam_id INT, question_id INT, answer TEXT,
  saved_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (student_id, exam_id, question_id));
CREATE TABLE IF NOT EXISTS submissions (
  id SERIAL PRIMARY KEY, student_id TEXT, s3_key TEXT, created_at TIMESTAMPTZ DEFAULT now());
CREATE TABLE IF NOT EXISTS results (
  student_id TEXT, exam_id INT, score INT, PRIMARY KEY (student_id, exam_id));
