INSERT INTO exams (id, title, duration_min) VALUES (1, 'Cloud Fundamentals Quiz', 30)
  ON CONFLICT DO NOTHING;
INSERT INTO questions (exam_id, text, options, correct) VALUES
 (1, 'Which AWS service stores objects?', '["Amazon S3","Amazon EBS","Amazon RDS"]', 'Amazon S3'),
 (1, 'Which service provides a managed Multi-AZ relational database?', '["DynamoDB","Amazon RDS","SQS"]', 'Amazon RDS'),
 (1, 'Which service decouples producers and consumers with a queue?', '["Amazon SQS","CloudFront","Route 53"]', 'Amazon SQS'),
 (1, 'Which service filters malicious web traffic at the edge?', '["AWS WAF","AWS KMS","Amazon SES"]', 'AWS WAF');
