# Secret Types

Genesis supports various types of secrets for different use cases. Each type has specific generation parameters and storage formats.

## Password Secrets

### Basic Passwords

Simple random password generation:

```yaml
credentials:
  base:
    admin_password: random 32
```

Generates a 32-character random password.

### Advanced Password Options

```yaml
credentials:
  base:
    db/password:
      password: "random 64 fmt base64"
    
    api/key:
      key: "random 40 allowed-chars a-zA-Z0-9_-"
    
    simple/pin:
      pin: "random 6 allowed-chars 0-9"
```

Parameters:
- **Length**: Number of characters (e.g., `32`, `64`)
- **Format**: `fmt base64` for base64 encoding
- **Allowed chars**: Specify character set
- **Fixed**: Add `fixed` to prevent rotation

### Password Storage

Stored as simple key-value:
```
secret/us-east-1/prod/cf/admin_password
└── value: "GeneratedPassword123!"
```

## SSH Keys

### Standard SSH Keys

```yaml
credentials:
  base:
    jumpbox/ssh: ssh 2048
    bastion/ssh: ssh 4096 fixed
```

Generates RSA keypair with specified bit size.

### SSH Key Storage

Stored with public and private keys:
```
secret/us-east-1/prod/cf/jumpbox/ssh
├── private: "-----BEGIN RSA PRIVATE KEY-----..."
├── public: "ssh-rsa AAAAB3NzaC1yc2EA..."
├── fingerprint: "SHA256:..."
└── format: "openssh"
```

### Using SSH Keys

```bash
# Extract private key
safe get secret/path/to/ssh:private > id_rsa
chmod 600 id_rsa

# Get public key
safe get secret/path/to/ssh:public > id_rsa.pub

# SSH using the key
ssh -i id_rsa user@host
```

## X.509 Certificates

### Certificate Definition

```yaml
certificates:
  base:
    ca:
      valid_for: 10y
      is_ca: true
    
    server:
      valid_for: 1y
      names: 
        - "*.system.cf.example.com"
        - "*.apps.cf.example.com"
        - "10.0.0.5"
```

### Certificate Parameters

- **valid_for**: Duration (e.g., `1y`, `365d`, `8760h`)
- **is_ca**: Boolean for CA certificates
- **names**: DNS names and IPs (SAN entries)
- **signed_by**: Path to signing CA

### Advanced Certificate Options

```yaml
certificates:
  haproxy:
    ssl/ca:
      is_ca: true
      valid_for: "${params.ca_validity_period}"
    
    ssl/server:
      signed_by: ssl/ca
      names: "${params.haproxy_domains}"
      valid_for: 90d
    
    mtls/client:
      signed_by: ssl/ca
      names: ["client.internal"]
      valid_for: 30d
```

### Certificate Storage

```
secret/us-east-1/prod/cf/ssl/server
├── cert: "-----BEGIN CERTIFICATE-----..."
├── key: "-----BEGIN RSA PRIVATE KEY-----..."
├── ca: "-----BEGIN CERTIFICATE-----..."
├── combined: "cert + key concatenated"
└── chain: "cert + ca concatenated"
```

### Certificate Operations

```bash
# View certificate details
safe x509 show secret/path/to/cert

# Validate certificate
safe x509 validate secret/path/to/cert \
  --ca secret/path/to/ca

# Check expiration
safe x509 expires secret/path/to/cert
```

## RSA Keys

### RSA Key Generation

```yaml
credentials:
  base:
    jwt/signing_key: rsa 4096
    encryption/key: rsa 2048 fixed
```

### RSA Key Storage

```
secret/us-east-1/prod/cf/jwt/signing_key
├── private: "-----BEGIN RSA PRIVATE KEY-----..."
├── public: "-----BEGIN PUBLIC KEY-----..."
└── format: "pem"
```

### Using RSA Keys

```bash
# Extract for JWT libraries
safe get secret/path/jwt/signing_key:private > jwt.key
safe get secret/path/jwt/signing_key:public > jwt.pub

# Convert formats if needed
openssl rsa -in jwt.key -pubout -out jwt.pub.pem
```

## DH Parameters

### Diffie-Hellman Parameters

```yaml
credentials:
  base:
    nginx/dhparams: dhparam 2048
    haproxy/dhparams: dhparam 4096 fixed
```

### DH Storage

```
secret/us-east-1/prod/cf/nginx/dhparams
└── value: "-----BEGIN DH PARAMETERS-----..."
```

## UUIDs

### UUID Generation

```yaml
credentials:
  base:
    consul/encryption_key:
      key: uuid
    
    bbs/encryption_key:
      key: "uuid v4"
    
    app/instance_id:
      id: "uuid v4 namespace dns name app.example.com"
```

### UUID Types

- **v4**: Random UUID (most common)
- **v5**: Namespace-based (deterministic)

### UUID Storage

```
secret/us-east-1/prod/cf/consul/encryption_key
└── key: "550e8400-e29b-41d4-a716-446655440000"
```

## User-Provided Secrets

### Definition

For secrets that can't be generated:

```yaml
provided:
  base:
    external/api:
      type: generic
      keys:
        client_id:
          type: string
          prompt: "Enter the OAuth client ID"
        
        client_secret:
          type: string
          sensitive: true
          prompt: "Enter the OAuth client secret"
        
        private_key:
          type: string
          multiline: true
          prompt: "Paste the private key (Ctrl-D when done)"
```

### Provided Secret Parameters

- **type**: Always `generic` currently
- **sensitive**: Hide input (for passwords)
- **multiline**: Accept multiple lines
- **prompt**: User prompt message
- **fixed**: Prevent regeneration

## Complex Secret Structures

### Multi-Component Secrets

Some secrets have multiple related parts:

```yaml
# Database with multiple credentials
credentials:
  base:
    db/admin:
      username: "admin"
      password: "random 32"
    
    db/app:
      username: "app_user"  
      password: "random 32"
    
    db/read_only:
      username: "reader"
      password: "random 24"
```

### Hierarchical Secrets

Organize related secrets:

```
secret/us-east-1/prod/cf/
├── db/
│   ├── admin/
│   │   ├── username
│   │   └── password
│   ├── app/
│   │   ├── username
│   │   └── password
│   └── uri  # Constructed from components
├── nats/
│   ├── username
│   ├── password
│   └── client_cert/
│       ├── cert
│       └── key
```

## Secret Validation

### Built-in Validation

Genesis validates secrets during generation:

```yaml
# This will fail - names required for non-CA certs
certificates:
  base:
    bad/cert:
      valid_for: 1y
      # Missing: names
```

### Manual Validation

```bash
# Check certificate validity
safe x509 validate secret/path/to/cert

# Verify SSH key
ssh-keygen -l -f <(safe get secret/path/to/ssh:public)

# Test password complexity
safe get secret/path/to/password | pwscore
```

## Secret References

### Using Parameters

Reference kit parameters in secret definitions:

```yaml
# In kit.yml
certificates:
  base:
    haproxy/ssl:
      valid_for: "${params.cert_validity_period}"
      names: "${params.haproxy_domains}"

# In environment file
params:
  cert_validity_period: 90d
  haproxy_domains:
    - haproxy.example.com
    - lb.example.com
```

### Cross-References

Reference other secrets:

```yaml
certificates:
  base:
    intermediate/ca:
      is_ca: true
      signed_by: root/ca  # References another cert
    
    server/cert:
      signed_by: intermediate/ca
      names: ["web.example.com"]
```

## Best Practices

### 1. Use Appropriate Types

Choose the right secret type:
- Passwords for authentication
- SSH keys for system access
- Certificates for TLS
- RSA keys for signing/encryption

### 2. Set Proper Lifetimes

```yaml
certificates:
  base:
    ca:
      valid_for: 10y  # Long for CAs
    server:
      valid_for: 90d  # Short for servers
```

### 3. Use Fixed Sparingly

Only use `fixed` for:
- External integrations
- Shared secrets
- Keys that can't be rotated

### 4. Organize Hierarchically

```yaml
credentials:
  base:
    # Group by component
    router/password: random 32
    router/ssl/cert: ...
    
    # Group by function
    admin/ui_password: random 32
    admin/api_key: random 64
```

### 5. Document Requirements

```yaml
provided:
  slack:
    notifications/webhook:
      keys:
        url:
          prompt: "Enter Slack webhook URL (from https://slack.com/apps/)"
```

Understanding these secret types helps you properly secure your Genesis deployments while maintaining operational simplicity.