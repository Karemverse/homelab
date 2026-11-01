#!/bin/bash
# Home CA ceremony. Run in macOS Terminal.app, NOT in the Claude app:
#   bash ~/Documents/Homelab/Homelab/pki/ceremony.sh
# The root key is created in a temp folder, stored by you in the password manager (+ paper), then deleted.
# It never goes to the server, git, or Claude. Only public certificates and fingerprints are written to the repo.
set -euo pipefail
T=~/Documents/Homelab/Homelab/pki
REPO=~/Documents/Homelab/Homelab
pause() { echo; read -r -p ">>> $1  [Enter to continue] " _; }
say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

umask 077
W=$(mktemp -d); cd "$W"
trap 'cd ~; rm -rf "$W"; pbcopy </dev/null; echo; echo "Temp folder deleted, clipboard cleared."' EXIT

say "1/7  Root passphrase"
echo "In the password manager: New item 'homelab — Homelab root CA passphrase', generate >= 20 characters, save."
echo "You will type it 3 times below (create, confirm, then to sign the intermediate and the test CA)."
pause "Passphrase saved in the password manager?"

say "2/7  Create the root (10 years) and the intermediate (396 days)"
step certificate create "Homelab Root CA 2026" homelab-root.crt homelab-root.key \
  --template "$T/root.tpl" --kty EC --curve P-256 --not-after 87600h
step certificate create "Homelab Intermediate CA 2026" homelab-intermediate.crt homelab-intermediate.key \
  --template "$T/intermediate.tpl" --ca homelab-root.crt --ca-key homelab-root.key \
  --kty EC --curve P-256 --not-after 9504h --no-password --insecure
echo; echo "Name constraints (root, then intermediate):"
step certificate inspect homelab-root.crt | grep -i -A5 'name constraints'
step certificate inspect homelab-intermediate.crt | grep -i -A5 'name constraints'
openssl verify -CAfile homelab-root.crt homelab-intermediate.crt
FP_ROOT=$(step certificate fingerprint homelab-root.crt)
FP_INT=$(step certificate fingerprint homelab-intermediate.crt)
END_ROOT=$(openssl x509 -in homelab-root.crt -noout -enddate | cut -d= -f2)
END_INT=$(openssl x509 -in homelab-intermediate.crt -noout -enddate | cut -d= -f2)
echo "Root SHA-256: $FP_ROOT"

say "3/7  Store the encrypted root key"
pbcopy < homelab-root.key
echo "The ENCRYPTED root key is on your clipboard."
echo "the password manager: New -> Note 'homelab — Homelab root CA key (encrypted PEM)' -> paste -> save."
pause "Key note saved in the password manager?"
pbcopy </dev/null
echo "Paper: print it now (if a printer is set up) or copy it later from the password manager by hand."
read -r -p ">>> Print the encrypted key now? [y/N] " p; [[ "$p" =~ ^[yY] ]] && lp homelab-root.key || true
echo "Write the passphrase on the same sheet; keep it at home, never with the external."

say "4/7  Intermediate to the server (the root KEY never goes there)"
ssh homelab 'sudo install -d -m 700 /srv/data/core-caddy/pki'
for f in homelab-root.crt homelab-intermediate.crt; do ssh homelab "sudo tee /srv/data/core-caddy/pki/$f >/dev/null" < "$f"; done
ssh homelab 'sudo sh -c "umask 077; cat > /srv/data/core-caddy/pki/homelab-intermediate.key"' < homelab-intermediate.key
ssh homelab 'sudo chmod 644 /srv/data/core-caddy/pki/*.crt; sudo chmod 600 /srv/data/core-caddy/pki/*.key; sudo ls -l /srv/data/core-caddy/pki'
cp homelab-root.crt "$T/homelab-root.crt"; chmod 644 "$T/homelab-root.crt"
cp homelab-root.crt ~/Desktop/homelab-root.crt; chmod 644 ~/Desktop/homelab-root.crt

say "5/7  Trust the root on this Mac (SSL only; macOS asks for your password)"
security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain-db homelab-root.crt
security dump-trust-settings 2>/dev/null | grep -i -A4 homelab || true

say "6/7  Constraint tests on the Mac (type the root passphrase once more for the throw-away CA)"
step certificate create "Throw-away unconstrained test CA" open.crt open.key --template "$T/open.tpl" \
  --ca homelab-root.crt --ca-key homelab-root.key --kty EC --curve P-256 --not-after 1h --no-password --insecure
MAGIC=laptop.tailnet-name.ts.net
I=(--ca homelab-intermediate.crt --ca-key homelab-intermediate.key --not-after 1h --kty EC --no-password --insecure)
O=(--ca open.crt --ca-key open.key --not-after 1h --kty EC --no-password --insecure)
step certificate create ok.homelab.internal ok.crt ok.key --san ok.homelab.internal "${I[@]}" >/dev/null
step certificate create constraint-test.example bad.crt bad.key --san constraint-test.example "${I[@]}" >/dev/null
step certificate create 100.64.0.20 badip.crt badip.key --san 100.64.0.20 "${I[@]}" >/dev/null
step certificate create "$MAGIC" baddns.crt baddns.key --san "$MAGIC" "${I[@]}" >/dev/null
step certificate create constraint-test.example rbad.crt rbad.key --san constraint-test.example "${O[@]}" >/dev/null
step certificate create 100.64.0.20 rbadip.crt rbadip.key --san 100.64.0.20 "${O[@]}" >/dev/null
step certificate create "$MAGIC" rbaddns.crt rbaddns.key --san "$MAGIC" "${O[@]}" >/dev/null
v() { if security verify-cert -c "$1" -c "$2" -p ssl ${3:+-n "$3"} -L >/dev/null 2>&1; then echo accepted; else echo refused; fi; }
R_OK=$(v ok.crt homelab-intermediate.crt ok.homelab.internal)
R_BAD=$(v bad.crt homelab-intermediate.crt constraint-test.example)
R_RBAD=$(v rbad.crt open.crt constraint-test.example)
R_RBADIP=$(v rbadip.crt open.crt "")
printf '  ok (in zone)            : %s   (want accepted)\n  bad  (intermediate)     : %s   (want refused)\n  rbad (root constraint)  : %s   (want refused)\n  rbadip (root, IP)       : %s   (want refused)\n' "$R_OK" "$R_BAD" "$R_RBAD" "$R_RBADIP"

say "7/7  Phone"
echo "1. Send ~/Desktop/homelab-root.crt to the Phone (public file: email to yourself, Drive, cable)."
echo "2. Phone: Settings > Security & privacy > More security & privacy > Encryption & credentials"
echo "   > Install a certificate > CA certificate > Install anyway > pick the file."
echo "3. Same screen > Trusted credentials > User > Homelab Root CA 2026: fingerprint must be"
echo "   $FP_ROOT"
read -r -p ">>> Run the browser test now (Phone Chrome + Mac Safari/Brave)? [Y/n] " t
PHONE="skipped"
if [[ ! "$t" =~ ^[nN] ]]; then
  cat badip.crt homelab-intermediate.crt > 8443.pem; cp badip.key 8443.key
  cat rbadip.crt open.crt > 8444.pem; cp rbadip.key 8444.key
  cat baddns.crt homelab-intermediate.crt > 8445.pem; cp baddns.key 8445.key
  cat rbaddns.crt open.crt > 8446.pem; cp rbaddns.key 8446.key
  echo "Open each on the Phone (Chrome) and the Mac (Safari): every one must show a certificate ERROR,"
  echo "never the text 'CONSTRAINT NOT ENFORCED':"
  echo "  https://100.64.0.20:8443/    https://laptop.tailnet-name.ts.net:8445/"
  echo "  https://100.64.0.20:8444/    https://laptop.tailnet-name.ts.net:8446/"
  echo "(If macOS asks whether python3 may accept connections: Allow. Press Ctrl-C here when done.)"
  /opt/homebrew/bin/python3 - <<'PY' || true
import http.server, ssl, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'CONSTRAINT NOT ENFORCED\n')
    def log_message(self, *a): pass
for port in (8443, 8444, 8445, 8446):
    srv = http.server.HTTPServer(('100.64.0.20', port), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(f'{port}.pem', f'{port}.key')
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
try:
    threading.Event().wait()
except KeyboardInterrupt:
    pass
PY
  read -r -p ">>> Did ALL 8 page loads show a certificate error? [y/N] " r
  [[ "$r" =~ ^[yY] ]] && PHONE="all refused" || PHONE="SOME ACCEPTED - tell Claude"
fi

# Public record only: fingerprints, dates, results, item names. Never key material.
mkdir -p "$REPO/docs"
cat >> "$REPO/docs/credentials.md" <<EOF

## Homelab CA($(date +%F))
| Item | Value |
|---|---|
| Root | "Homelab Root CA 2026", SHA-256 \`$FP_ROOT\`, ends $END_ROOT |
| Intermediate | "Homelab Intermediate CA 2026", SHA-256 \`$FP_INT\`, ends $END_INT (rotate 11 months after creation, runbook R-CA) |
| Root key | only in the password manager ("homelab — Homelab root CA key (encrypted PEM)" + "homelab — Homelab root CA passphrase") and on paper at home |
| Server | /srv/data/core-caddy/pki: both .crt + homelab-intermediate.key (600) |
| Mac verify-cert | ok: $R_OK; bad (intermediate): $R_BAD; rbad (root): $R_RBAD; rbadip (root, IP): $R_RBADIP |
| Browser test (Phone Chrome, Mac Safari) | $PHONE |
EOF
say "Done. Tell Claude: 'ca done' (and anything that was not as expected)."
echo "Calendar: add a reminder 11 months from today: 'rotate the Homelab intermediate (runbook R-CA)'."
