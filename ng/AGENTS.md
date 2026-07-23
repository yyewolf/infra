# ng directory - Home network infrastructure

Terraform-managed home network config using the MikroTik RouterOS provider and SOPS for secrets.

## Structure

```
ng/
├── router/           # MikroTik router configuration
│   ├── main.tf       # Root: providers, data sources, module calls
│   ├── provider.tf    # RouterOS provider (192.168.1.49, insecure=true)
│   ├── variables.tf   # wan_interface, wan_hostname, lan_interface_list, wan_interface_list
│   ├── router-sops.yaml   # SOPS-encrypted router credentials (secrets.username, secrets.password)
│   └── modules/
│       ├── wan/          # DHCP client, ethernet, DNS, mDNS
│       ├── ip-firewall/  # IPv4 firewall filter + NAT rules
│       ├── ipv6-firewall/# IPv6 firewall filter + address lists
│       └── wireguard/    # WireGuard interface, IP, and peers
└── wireguard/
    ├── identities-sops.yaml  # SOPS-encrypted WG identity registry
    ├── gen-identity.sh       # Generate keypair for one identity
    └── gen-all.sh            # Regenerate all keys
```

## Key conventions

- **SOPS encrypted files** must match pattern `.*-sops\.yaml$` in `.sops.yaml` at repo root. Encrypted keys go under `secrets:` key (matches `encrypted_regex: ^(data|stringData|secrets)$`).
- **RouterOS provider** connects to `https://192.168.1.49` with `insecure = true` (self-signed cert, no IP SANs).
- **Terraform modules** in `modules/` each declare their own `required_providers { routeros {} }` block (no version pin in sub-modules).
- **WireGuard identities** — private keys are under `secrets:` (encrypted), public keys/addresses/ports under `identities:` (plaintext). Use `nonsensitive()` on the identities map when iterating peers since Terraform marks the whole `data.sops_file.raw` as sensitive.
- **Firewall rule IDs** — this router uses hex IDs (*A, *B, etc.), numbering starts at *1 (not *0).

## Rules

- **NEVER** read terraform state files (`*.tfstate`, `*.tfstate.backup`, `.terraform/`).
- **NEVER** read SOPS-encrypted files or decrypted secrets. Use `data.sops_file` in Terraform — do not inspect actual credential values.
- **NEVER** commit secrets, private keys, or unencrypted credentials.
- When adding a new WireGuard peer, run `./wireguard/gen-identity.sh <name> <address>` from the `ng/` directory, then update `router/main.tf` locals if needed.

## State management

State is encrypted with SOPS and committed to git. Use the wrapper script (`tf.sh`) instead of calling terraform directly — it decrypts state before use and re-encrypts on exit.

State file: `ng/router/terraform-state.gpg` (PGP-encrypted blob, tracked in git)
Plaintext: `ng/router/terraform.tfstate` (temporary, gitignored, never committed)

## Commands

```sh
# Plan router changes (uses encrypted state)
./ng/router/tf.sh plan

# Apply changes
./ng/router/tf.sh apply

# Destroy
./ng/router/tf.sh destroy

# Init (no state needed, but cd required)
cd ng/router && terraform init

# Regenerate all WireGuard keys
./ng/wireguard/gen-all.sh

# Add a new WireGuard identity
./ng/wireguard/gen-identity.sh my-peer 10.10.0.3/32
```
