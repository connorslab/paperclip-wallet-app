# Pairing TLS fixtures

These generated certificates and the unencrypted test server key are synthetic.
They are used only by the loopback unit-test server. They are not wallet,
production TLS, or release-signing material. The CA private key was discarded.

The leaf is signed by the fixture CA and has DNS names `localhost` and
`pairing-fixture.local`, deliberately excluding 127.0.0.1 so hostname rejection
can be tested. It is valid November 2026–November 2036. Tests also use the separate
remote-node fixture certificate as an unrelated root. Nothing contacts StartOS,
a real wallet or an external node.
