#!/usr/bin/env bash
# tailscale-ips.sh — extract Tailscale IPs and print flake.nix update snippets.
#
# Run this on any Tailscale node after bringing up the network. It reads the
# current tailscale status, matches hostnames against the known topology, and
# prints the exact text to paste into flake.nix.
#
# Prerequisites: tailscale, jq
#
# Usage:
#   ./scripts/tailscale-ips.sh
#   ./scripts/tailscale-ips.sh --env   # deprecated alias (no additional output)

set -euo pipefail

PRINT_ENV=false
for arg in "$@"; do
  case "$arg" in
    --env) PRINT_ENV=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Validate dependencies
for dep in tailscale jq; do
  if ! command -v "$dep" &>/dev/null; then
    echo "ERROR: '$dep' is required but not installed." >&2
    exit 1
  fi
done

# Validate tailscale is authenticated
if ! tailscale status &>/dev/null; then
  echo "ERROR: tailscale is not running or not authenticated." >&2
  exit 1
fi

# Hostnames to look for (must match tailscale machine names)
readonly HOSTS=(cerberus metis dionysus panoptes tartarus hephaestus)

echo "Reading tailscale status..."
STATUS_JSON=$(tailscale status --json)

if $PRINT_ENV; then
  echo "NOTE: --env is deprecated. Tailscale IPs are injected via NixOS systemd units."
fi

declare -A IPS

for host in "${HOSTS[@]}"; do
  ip=$(echo "$STATUS_JSON" | jq -r --arg name "$host" '
    # Check self first
    if (.Self.DNSName | ascii_downcase | split(".")[0]) == $name then
      .Self.TailscaleIPs[0]
    else
      # Check peers
      (.Peer | to_entries[]
        | select(
            (.value.DNSName | ascii_downcase | split(".")[0]) == $name
          )
        | .value.TailscaleIPs[0]
      )
    end
  ' 2>/dev/null | head -1)

  if [[ -z "$ip" || "$ip" == "null" ]]; then
    echo "  WARNING: could not find tailscale IP for '$host' — is it online?" >&2
    IPS[$host]="MISSING"
  else
    IPS[$host]="$ip"
    echo "  Found: $host → $ip"
  fi
done

echo ""
echo "================================================================"
echo "  flake.nix — replace the tailscale block with:"
echo "================================================================"
echo ""
echo "      tailscale = {"
echo "        cerberus = \"${IPS[cerberus]:-MISSING}\";   # ← $([ "${IPS[cerberus]:-MISSING}" = "MISSING" ] && echo "NOT FOUND" || echo "updated")"
echo "        metis    = \"${IPS[metis]:-MISSING}\";   # ← $([ "${IPS[metis]:-MISSING}" = "MISSING" ] && echo "NOT FOUND" || echo "updated")"
echo "        dionysus = \"${IPS[dionysus]:-MISSING}\";   # ← $([ "${IPS[dionysus]:-MISSING}" = "MISSING" ] && echo "NOT FOUND" || echo "updated")"
echo "        panoptes = \"${IPS[panoptes]:-MISSING}\";   # ← $([ "${IPS[panoptes]:-MISSING}" = "MISSING" ] && echo "NOT FOUND" || echo "updated")"
echo "        tartarus = \"${IPS[tartarus]:-MISSING}\";   # ← $([ "${IPS[tartarus]:-MISSING}" = "MISSING" ] && echo "NOT FOUND" || echo "updated")"
echo "        hephaestus = \"${IPS[hephaestus]:-MISSING}\";   # ← $([ "${IPS[hephaestus]:-MISSING}" = "MISSING" ] && echo "NOT FOUND" || echo "updated")"
echo "      };"

echo ""
echo "After editing flake.nix, run:"
echo "  nix flake lock --update-input nixpkgs   # only needed after nixpkgs bumps"
echo "  nixos-rebuild switch --flake .#<host>   # on each host"
