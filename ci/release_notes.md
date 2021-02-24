# Improvements

- Can now update subject, SAN, and usage of vault-stored certificates without
  generating a new key with `genesis rotate-secrets --renew`  This allows
  users to correct warnings that show up in the check during deployment
  without breaking mutual TLS. (Note this will also renew the TTL for the
  certificates)
