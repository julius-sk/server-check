<!-- Author: Lei Zhao <lei1.zhao@sk.com> -->

# HTTPS download CA certificates

Lab TLS inspection uses the SK Hynix internal CA chain. Without it in the
system trust store, HTTPS downloads may fail certificate verification.

`SK_Hynix_America_Root_CA.crt` is the trust anchor. It signs the subordinate
CA, which signs inspected connections. Both files are safely distributable
public certificates; they contain no private key and cannot issue certificates.

Step 01 verifies the bundled checksums and pinned certificate fingerprints,
installs the files as `root:root 0644`, refreshes the Debian CA bundle, and
repairs the OpenSSL `cert.pem` link when needed. A Cisco WSA HTTP 403 is a
policy result, not a certificate verification failure.
