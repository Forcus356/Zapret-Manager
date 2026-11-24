# Security

English · [Русский](SECURITY.ru_RU.md)

## Reporting a vulnerability

Do not publish credentials, full client configs or working exploit details in a public Issue. Use the repository's **Security → Report a vulnerability** if private vulnerability reporting is enabled. If it is unavailable, open a minimal Issue requesting a private reporting channel, without secrets or a reproducible attack against a live system. No private reporting address is advertised here.

Include the manager version, OS, affected component, expected behavior and a redacted explanation of the impact. Version 1.0.0 is the initial release; check current maintenance status before deploying an older copy.

## Deployment model

- Installation and management require root because they modify system services, packet handling and optional Xray configuration.
- SOCKS listens on loopback without a client password. Keep Xray's administrative API local. Neither endpoint is intended for public exposure.
- Dante blocks TCP destinations in local/private/service networks; this restriction is not a general claim that every protocol is filtered identically.
- Packet handling is scoped to profile users and owned nftables tables. The manager does not flush the complete firewall.
- Zapret2 is downloaded from official releases with a pinned SHA256. This verifies the expected archive, not the trustworthiness of every possible upstream release or an independently downloaded installer.
- State and backups can contain infrastructure/configuration data. Keep them private and redact reports before sharing.
- Managed removal checks recorded Xray bindings; external/manual consumers still require an operator review.
- A running service or successful HTTPS probe does not prove that every provider, destination, call or video path works.

See [operations](docs/operations.md), [tests](tests/README.md), [verification limits](docs/testing.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
