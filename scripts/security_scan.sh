#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

status=0

while IFS= read -r -d '' path; do
    case "$path" in
        *.p8|*.p12|*.mobileprovision|*.provisionprofile|*.cer|*.key|*.pem|.env|.env.*)
            echo "Forbidden sensitive file tracked: $path" >&2
            status=1
            ;;
    esac
done < <(git ls-files -co --exclude-standard -z)

while IFS= read -r -d '' path; do
    if [[ "$path" != "scripts/security_scan.sh" ]] && rg -n -I -e '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN CERTIFICATE-----' -- "$path"; then
        echo "Potential credential or private key material found in: $path" >&2
        status=1
    fi

    case "$path" in
        *.swift|*.yml|*.yaml|*.md|*.xcconfig|*.json)
            if rg -n -I -e '/root/|/Users/[^/]+/|\\b[A-Za-z]:\\\\Users\\\\' -- "$path"; then
                echo "Machine-specific absolute path found in: $path" >&2
                status=1
            fi
            ;;
    esac
done < <(git ls-files -co --exclude-standard -z)

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

echo "Security scan passed: no signing files, private-key material, or machine-specific paths found."
