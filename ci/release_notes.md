# Improvements

This release contains improvements to Pipeline Generation and Integration

* Enable Enterprise Vault support, use Safe to init

  Instead of using the Vault Genesis kit, some clients need to integrate with
  their companies Enterprise Vault.  This means supporting namespaces and
  disabling strongbox, the process that Safe uses to treat multiple Vault VMs
  as a single target when unsealing.

  Since Safe nicely wraps up support for this, the pipelines have been updated
  to use Safe to initialize connections to the Vault, making it seamless
  regardless of it being Enterprise or not, v1 or v2 kv backend.

  Changes:
    - In your `ci.yml`, under `pipeline.vault`, you can specify `namespace` as
      a string, and `no-strongbox` as a truthy value to connect to your
      enterprise vault.

* More dynamic 'default' pipeline layout.

  If ci.yml specifies a `default` layout, that layout will be used without
  having to specify it, but it will expect the fly target to also be `default`
  -- this is at odds with the concourse `login` addon which names the fly
  target the same as the environment name.

  To resolve this, if you only have a single layout in your `ci.yml` file, it
  will be considered the default, so it can be named the same as your fly
  target aka concourse environment.  If you have muptiple layouts, a layout
  named `default`, if it exists, will be considered default to keep existing
  behaviour.  Otherwise, if you have multiple named layouts and you didn't
  specify one in the `repipe` command, it will present you with a list to
  chose from.  The `-t|--target` command will still behave as normal.

* Use use https instead of ssh for git in pipeliens

  Some places must use https endpoints with basic auth for accessing git
  repositories instead of ssh with keys.  This enables that ability.

  Change in behaviour:
    - In the `ci.yml` file, under `pipeline.git`, you specify `username` and
      `password` instead of `private_key`
    - If `username` and `password` are used, the URI used will be
      `https://<host>/<owner>/<repo>.git` but this can be specified directly
      using `pipeline.git.uri`
