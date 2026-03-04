#!/bin/bash
# 08-playwright.sh — Playwright system dependencies for functional tests
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing Playwright system dependencies..."

# Install only system libraries (X11, GStreamer, fonts, etc.) needed by browsers.
# Browser binaries are installed at boot from the workspace's pinned Playwright
# version to avoid version mismatches.
npx playwright install-deps firefox chromium

echo "==> Playwright system dependencies installed."
