#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUSTMEM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

chmod +x "${TRUSTMEM_DIR}/bin/trustmem"
chmod +x "${TRUSTMEM_DIR}/scripts/"*.sh

if [[ ! -f "${TRUSTMEM_DIR}/.env" ]]; then
  cp "${TRUSTMEM_DIR}/.env.example" "${TRUSTMEM_DIR}/.env"
  echo "Created .env from .env.example"
else
  echo "Kept existing .env"
fi

if [[ ! -f "${TRUSTMEM_DIR}/projects-map.yaml" ]]; then
  cp "${TRUSTMEM_DIR}/projects-map.example.yaml" "${TRUSTMEM_DIR}/projects-map.yaml"
  echo "Created projects-map.yaml from projects-map.example.yaml"
else
  echo "Kept existing projects-map.yaml"
fi

echo "Install bootstrap complete."
