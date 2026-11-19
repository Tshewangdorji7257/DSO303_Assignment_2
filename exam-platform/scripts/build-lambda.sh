#!/usr/bin/env bash
# Builds app/marker/pkg (used by Terraform). Works on Windows Git Bash, Linux, macOS, CI.
set -euo pipefail
cd "$(dirname "$0")/../app/marker"
rm -rf pkg && mkdir pkg
pip install -r requirements.txt -t pkg \
  --platform manylinux2014_x86_64 --only-binary=:all: --python-version 3.12 --implementation cp
cp handler.py init_db.py pkg/
cp ../api/schema.sql ../api/seed.sql pkg/
echo "Lambda package ready in app/marker/pkg"
