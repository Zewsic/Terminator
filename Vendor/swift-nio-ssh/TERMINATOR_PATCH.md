# Terminator SwiftNIO SSH RSA patch

Upstream base: apple/swift-nio-ssh pull request 219, commit
`96d8ebc153218291f0d5257aabaeb71ce961afc6`.

The upstream Apache-2.0 license is retained. Terminator's maintained delta:

- allows Swift Crypto 4.x;
- advertises RSA signatures as `rsa-sha2-512`, then `rsa-sha2-256`;
- rejects `ssh-rsa`/SHA-1 signature negotiation and decoding.

Remove this vendored package when equivalent RFC 8332 support ships upstream.
