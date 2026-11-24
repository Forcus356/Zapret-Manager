# Third-party components

The manager is implemented as independent Python code. Its menu/workflow was inspired by [Forcus Psiphon Auto Pin Manager](https://github.com/Forcus356/Psiphon-Auto-Pin-Manager), reference commit `cfe8c3b2d798a7ad9180d31d249b9f17f7af9ba5`.

The distribution contains no bundled proxy binaries, Telegram account data, server passwords or client credentials.

- **Zapret2**: downloaded from the official [bol-van/zapret2](https://github.com/bol-van/zapret2) releases with a pinned SHA256. Consult the upstream repository and release for its license. The installer extracts the x86_64 executable, Lua files and fake payload resources into its own directory.
- **Dante, nftables, Python, cryptography and other system packages**: installed through the server's Ubuntu/Debian package manager. Their licenses remain with the distribution packages.
- **Xray**: an existing external installation. The manager uses its local administrative API and JSON configuration; it does not redistribute the binary. Integration tests may supply an existing Xray binary and public geodata in a disposable container.
- **Telegram CIDR and bootstrap addresses**: configuration data from the official Telegram resource list and Telegram Desktop source. The unauthenticated test uses the public MTProto transport specification and never authenticates an account.

Strategies were reproduced from a functioning VPS configuration and validated using Zapret2's own parameter checks. Repository banners and menu illustrations are project assets; menu previews use demonstration data and are not live server screenshots.
