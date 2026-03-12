#!/usr/bin/env bash
# cert-status.sh — check ACME certificate expiry dates from Traefik.
#
# Reads the Traefik acme.json file to extract certificate domains and expiry
# dates. Runs locally on Panoptes where Traefik is deployed.
#
# Environment overrides:
#   ACME_JSON_PATH   Path to acme.json (default: /var/lib/appdata/ingress/letsencrypt/acme.json)
#
# Exit codes:
#   0 — all certs valid (>14 days)
#   1 — at least one cert expires within 14 days or error

set -euo pipefail

ACME_JSON_PATH="${ACME_JSON_PATH:-/var/lib/appdata/ingress/letsencrypt/acme.json}"

echo "=== Certificate Status — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""

if [[ ! -f "${ACME_JSON_PATH}" ]]; then
  echo "[cert-status] ERROR: acme.json not found at ${ACME_JSON_PATH}" >&2
  echo "[cert-status] Is Traefik running and using ACME?" >&2
  exit 1
fi

WARNING=0

# Parse acme.json — structure varies by resolver name
# Use process substitution to avoid subshell (preserves WARNING variable)
while read -r domain cert_b64; do
  if [[ -z "$domain" || -z "$cert_b64" ]]; then
    continue
  fi

  # Decode certificate and extract expiry
  expiry=$(echo "$cert_b64" | base64 -d 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | sed 's/notAfter=//')

  if [[ -z "$expiry" ]]; then
    echo "  [WARN] ${domain}: could not parse certificate"
    WARNING=1
    continue
  fi

  expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

  if [[ "$days_left" -lt 14 ]]; then
    echo "  [WARN] ${domain}: expires in ${days_left} days (${expiry})"
    WARNING=1
  else
    echo "  [OK]   ${domain}: ${days_left} days remaining (${expiry})"
  fi
done < <(jq -r '
  to_entries[] | .value.Certificates[]? |
  "\(.domain.main) \(.certificate)"
' "$ACME_JSON_PATH" 2>/dev/null)

echo ""
echo "=== End of Certificate Status ==="

if [[ "$WARNING" -gt 0 ]]; then
  exit 1
fi
