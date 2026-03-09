# Secrets in Genesis

Genesis supports various types of secrets that can be specified in `kit.yml` files within kits. These secrets are used to manage sensitive information securely. Below are the different types of secrets and their YAML definitions.

## X.509 Certificates

X.509 certificates are used for SSL/TLS encryption. They can be defined in the `certificates` section of the `kit.yml` file.

### Definition Structure

* `<feature_name>`: This is the top key type under the `certificates` section. It is used to group certificates by feature, so that certificates are only generated when the feature is enabled.  Use `base` for the default settings. 

  * `<path/to/certs>`: This is the path to the certificates under the base vault path for the environment.

    * `<cert_name>`: This is the identifing name of the cert, under the path group.  If the name is `ca`, it will be assumed to be a ca certificate that will be used to sign the other certificates in the group, such as `server` or `client`.

      The following are valid properties for a certificate:

	    * `valid_for`: This is the duration for which the certificate is valid. It is specified in the format `<duration>`, where `<duration>` is a number followed by a time unit. The time unit can be `h` for hours, `d` for days, `w` for weeks, `M` for months, or `y` for years.

	      It can also be specified as `${params.<param_name>}`, where `<param_name>` is the name of a parameter in the `params` section of the `<env>.yml` file.  This allows you to customize the duration based on the environment.

			* `names`:  This is a list of DNS names or IP addresses that the certificate is valid for.  It is specified as a comma separated list of names.  It can also be specified as `${params.<param_name>}`, where `<param_name>` is the name of a parameter in the `params` section of the `<env>.yml` file.  This allows you to customize the names based on the environment.  All non-CA certificates must have a `names` property, containing at least one name.

	    * `is_ca`: This is a boolean value that specifies whether the certificate is a CA certificate. Default is `false`, unless name is `ca`.

	    * `signed_by`: This is the path to the CA certificate that signed the certificate.  If a `ca` certificate is defined in the group, it will be used to sign the other certificates in the group if this is not specified.

### YAML Definition

```yaml
certificates:
  feature_name:
    path/to/cert:
      ca:
       valid_for: 1h 
      server:
        valid_for: 1h
        names: "example.com"
```

## User-Provided Secrets

User-provided secrets are values that users need to input manually. They can be defined in the `provided` section of the `kit.yml` file.

### YAML Definition

```yaml
provided:
  feature_name:
    path/to/secret:
      type: generic
      keys:
        key_name:
          type: string
          sensitive: true
          multiline: false
          prompt: "Enter the value for key_name"
          fixed: false
```

## Credentials

Credentials are used for authentication and can include SSH keys, RSA keys, random passwords, and UUIDs. They can be defined in the `credentials` section of the `kit.yml` file.

### YAML Definition

#### SSH Keys

```yaml
credentials:
  feature_name:
    path/to/ssh_key: "ssh 2048 fixed"
```

#### RSA Keys

```yaml
credentials:
  feature_name:
    path/to/rsa_key: "rsa 2048 fixed"
```

#### DH Parameters

```yaml
credentials:
  feature_name:
    path/to/dhparams: "dhparam 2048 fixed"
```

#### Random Passwords

```yaml
credentials:
  feature_name:
    path/to/password:
      key_name: "random 32 fmt base64 at key_name allowed-chars A-Za-z0-9 fixed"
```

#### UUIDs

```yaml
credentials:
  feature_name:
    path/to/uuid:
      key_name: "uuid v4 namespace dns name example.com fixed"
```

## Invalid Secrets

Invalid secrets are used to handle errors in secret definitions. They are automatically generated when there is an issue with the secret definition.

### YAML Definition

Invalid secrets do not have a specific YAML definition as they are generated based on errors in the other secret types.

## Example Kit YAML

Below is an example `kit.yml` file that includes all the different types of secrets.

```yaml
certificates:
  base:
    my/cert:
      ca:
        is_ca: true
        signed_by: "my/ca"
      server:
        signed_by: "my/ca"
        common_name: "example.com"

provided:
  base:
    my/secret:
      type: generic
      keys:
        api_key:
          type: string
          sensitive: true
          multiline: false
          prompt: "Enter the API key"
          fixed: false

credentials:
  base:
    my/ssh_key: "ssh 2048 fixed"
    my/rsa_key: "rsa 2048 fixed"
    my/dhparams: "dhparam 2048 fixed"
    my/password:
      admin_password: "random 32 fmt base64 at admin_password allowed-chars A-Za-z0-9 fixed"
    my/uuid:
      instance_id: "uuid v4 namespace dns name example.com fixed"
