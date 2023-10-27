Subjects:

### [KIT AUTHORSHIP] How to override kit certificate expiry dates

1. Specify the params in the base manifest.yml segment for the kit, with
   reasonable default values  You can add different periods to meet needs (ie
   long-lived api certs vs web portal certs that can't exceed 1y due to
   browsers).

```
params:
  ca_validity_period:   5y
  cert_validity_period: 1y
```

2. Specify the same thing in ci/test_params.yml so that the pipelines don't fail.

3. Specify the params in the cert definitions in kit.yml:
```
certificates:
  base:
    ssl:
      ca:
        valid_for: ${params.ca_validity_period}
      server:
        valid_for: ${params.cert_validity_period}
        names:
        - ${params.static_ip}
```

Now just set the params in each environment (or a shared base environment)
