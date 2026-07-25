"""Render a WireGuard config from the decrypted identity registry on stdin.

Invoked by gen-conf.sh; reads JSON so no YAML dependency is needed.
"""

import json
import sys


def die(message):
    sys.exit("ERROR: " + message)


def main():
    name, peer_name, endpoint, allowed_ips, dns, keepalive = sys.argv[1:7]

    data = json.load(sys.stdin)
    identities = data.get("identities") or {}
    secrets = data.get("secrets") or {}

    known = ", ".join(sorted(identities)) or "none"
    if name not in identities:
        die("identity '%s' not in the registry (have: %s)" % (name, known))
    if peer_name not in identities:
        die("peer '%s' not in the registry (have: %s)" % (peer_name, known))
    if name == peer_name:
        die("identity and peer are both '%s'" % name)

    self_id = identities[name]
    peer_id = identities[peer_name]

    private_key = (secrets.get(name) or {}).get("private_key")
    if not private_key:
        die("no private key for '%s' under secrets:" % name)

    peer_public_key = peer_id.get("public_key")
    if not peer_public_key:
        die("no public key for peer '%s'" % peer_name)

    address = self_id.get("address")
    if not address:
        die("no address for '%s'" % name)

    # An empty endpoint in the registry means that side never dials out, so it
    # is the router that initiates. Usable, but only while this host stays
    # reachable at the address the router has for it.
    endpoint = endpoint or peer_id.get("endpoint") or ""
    if not endpoint:
        sys.stderr.write(
            "warning: no endpoint for '%s', the generated config can only\n"
            "         accept connections, not start them. Pass --endpoint to fix.\n"
            % peer_name
        )

    lines = ["[Interface]", "PrivateKey = " + private_key, "Address = " + address]

    listen_port = self_id.get("listen_port")
    if listen_port:
        lines.append("ListenPort = %s" % listen_port)
    if dns:
        lines.append("DNS = " + dns)

    lines += [
        "",
        "[Peer]",
        "# " + peer_name,
        "PublicKey = " + peer_public_key,
        "AllowedIPs = " + allowed_ips,
    ]
    if endpoint:
        lines.append("Endpoint = " + endpoint)
    if keepalive and keepalive != "0":
        lines.append("PersistentKeepalive = " + keepalive)

    print("\n".join(lines))


main()
