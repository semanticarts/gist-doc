#!/usr/bin/env bash
set -euo pipefail

WIDOCO_VERSION="1.4.25"
WIDOCO_JDK="17"
JAR_NAME="widoco-${WIDOCO_VERSION}-jar-with-dependencies_JDK-${WIDOCO_JDK}.jar"
JAR_URL="https://github.com/dgarijo/Widoco/releases/download/v${WIDOCO_VERSION}/${JAR_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR_PATH="${SCRIPT_DIR}/${JAR_NAME}"

if [[ -f "${JAR_PATH}" ]]; then
  echo "WIDOCO jar already present: ${JAR_PATH}"
  exit 0
fi

echo "Downloading ${JAR_NAME} ..."
curl -L --fail -o "${JAR_PATH}" "${JAR_URL}"
echo "Saved to ${JAR_PATH}"
