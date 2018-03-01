Writing a `hooks/new` Kit Hook
==============================

Starting in Genesis v2.5.0, Kit authors have more control over the
interaction with the user.  The `genesis new` interaction is a
prime example.  Previously, Genesis drove the entire interaction,
based on a YAML-based set of questions specified in the `kit.yml`
metadata file.  Now, we have `hooks/new`.

If it exists, the `new` hook is executed whenever an operator
tries to configure a brand new Genesis environment via `genesis
new`.  It is the hook's job to prompt the user for whatever
information is needed, and create a well-formed YAML file
representing that environment.

Let's look at a simple `new` hook:

```sh
#!/bin/bash
set -eu

root=$1      # absolute path to deployments directory
name=$2      # name of the new environment
prefix=$3    # vault prefix for storing secrets

cat >$root/$name.yml <<EOF
kit:
  features: []

params:
  env:   $name
  vault: $prefix
EOF
```

This hook is incredibly boring, but it illustrates two key
points.

First, the `new` hook receives three positional arguments: the
absolute path to the deployments directory, the name of the new
environment (hyphenated) and the slash-separated prefix to use by
default in the Vault.

Secondly, the last thing the hook does is populate the
`$root/$name.yml` file with the definition of the new environment.
At a bare minimum, this file must contain both `params.env` and
`params.vault`.

Let's make things a bit more interesting, and try to implement
something like a Vault kit, packaging the [Safe BOSH release][1].
The kit will implement a baseline Vault with a generated
certificate, and provide two feature flags: one (called ha) to
activate HA / clustering features, and another to enable custom
TLS certificates to be used, instead of generated certs.

Here's the first draft of the `new` hook, supporting the Vault HA:

```sh
#!/bin/bash
set -eu

root=$1
name=$2
prefix=$3

#### Do they want an HA Vault?

prompt_for is_ha boolean \
  'Do you want to cluster this Vault?'

instances=1
if [[ $is_ha == "true" ]]; then
  prompt_for instances line \
    'How many instances would you like to spin in your cluster?' \
    --validation '/^\d+$/'
fi

#### Generate the environment YAML file
(
cat <<EOF
kit:
  features:
EOF
if [[ $is_ha == "true" ]]; then
  echo "    - clustered"
fi

cat <<EOF

params:
  env:   $name
  vault: $prefix
EOF

if [[ $is_ha == "true" ]]; then
  echo
  echo "  # How many cluster nodes to spin"
  echo "  instances: $instances"
fi
) >$root/$name.yml
```


When a user runs `genesis new` for a new environment, the hook
script will fire and the interaction will look something like
this:

```
$ genesis new buffalo-lab --vault lab
Generating new environment buffalo-lab...

Using local development kit (./dev)...
Now targeting lab at https://10.0.0.5 (skipping TLS certificate verification)

Do you want to cluster this Vault?
[y|n] > y

How many instances would you like to spin in your cluster?
> 3

Generating secrets / credentials (in secret/buffalo/lab/vault)...
 - no credentials need to be generated.
 - no certificates need to be generated.

New environment buffalo-lab provisioned.
```

The resulting `buffalo-lab.yml` environment file looks like this:

```yaml
kit:
  features:
    - clustered

params:
  env:   buffalo-lab
  vault: buffalo/lab/vault

  # How many cluster nodes to spin
  instances: 3
```

As you can see, you have full control over the interaction, as
well as the format and contents of the generated environment file.
This is a great way to inject configuration-specific documentation
into the YAML, to assist the operator with next steps.


The Genesis `prompt_for` Helper
-------------------------------

Writing text-based UI widgets is kind of annoying, which is why
Genesis provides hooks written in Bash with a set of helper
functions.  Chief among those is `prompt_for`.

`prompt_for` is the Swiss Army knife of asking questions in a
`new` hook.  It can ask yes/no (boolean) questions.  It can ask
for a single string and validate it a variety of ways.  It can ask
for lists of things, etc.

The basic usage of the helper function is

```
prompt_for VARNAME type "Message to display to user" [OPTIONS]
```

`VARNAME` is the name of a Bash variable, without the leading `$`
sigil, which will house the answer provided by the user.

`type` identifies which type of prompt you want to display.  We'll
go over the specific types in just a moment.

The last _required_ argument is the message to show the user.

Depending on the `type` specified, `prompt_for` recognizes certain
arguments, which help you to modify the behavior of the prompting
machinery.

### `boolean` Prompts

Sometimes you just want to ask the user if they want to do
something or not.  That's where `boolean` prompts come in.

The following options are supported:

- **--default=[yn]** - Set the default value, to be used if the
  user doesn't actually answer the question.  By default, they
  will be re-prompted.
- **--invert** - Treat yes as no and no as yes.  This affects how
  the named variable gets its value.

If the user answers 'y' or 'yes', the named variable will be set
to the _string_ "true".  Otherwise, it gets the value "false"
(also a string).  The `--invert` flag flips this behavior.

Here's an example:

```
prompt_for use_shield boolean \
  'Do you want to use SHIELD to back up your data?'
```

### `line` Prompts

If you just need a single, scalar value like a bit of text or a
number, and don't need to support embedded newlines, you can use
the `line` prompt type.

The following options are suppored:

- **--label ...** - A label to use for the prompt.  This displays
  underneat the prompt message, to the left of where the user
  types in their value.
- **--default ...** - A default value to assume if the user does
  not specify anything.  By default, users will be prompted until
  they do enter a value.
- **--validation ...** - An optional strategy for validating user
  input.  See below for the particulars.

Available validations, for the `--validation` flag, are:

- **ip** checks that the supplied value is a well-formed IP
  address.  Suports both IPv4 and IPv6 (FIXME: check this)
- **url** ensures that the given value is parseable as a URL,
  with a proper scheme, host component and optional path and query
  string components.
- **port** validates that the value is a valid TCP or UDP port
  number, between 1 and 65535.
- Numeric ranges, like `3-5`, or `2-`, will validate that the
  input value is a whole number that falls within the prescribed
  range.
- Arbitrary, Perl-compatible regular expressions can be supplied
  to perform pattern matching validation.  These can be prefixed
  with the negation operator, '!' to flip the match disposition.

Here's a few examples:

```
prompt_for vcenter_ip line \
  'What is the IP address of your vCenter Server Appliance?' \
  --validation ip

prompt_for bosh_hostname line \
  'What hostname would you like to use for your BOSH director?' \
  --default bosh \
  --label '(hostname) '
```

### `block` Prompts

Text values with embedded line endings are called `blocks`, and
you can ask for them via the `block` type.

The `block` prompt does not support any options.

Here's an example:

```
prompt_for public_key block \
  'What is your RSA public key?'
```

### `select` Prompts

Often, there is a set list of possible values that the user can
choose from.  For example, the BOSH kit needs to know what type of
IaaS you want BOSH to orchestrate, but only supported cloud
providers can be used.  That's what `select` prompts are for.

Let's start with an example, before getting into the details of
supported options:

```
prompt_for iaas select \
  'Which IaaS do you want to deploy on?' \
  -o '[aws]     Amazon Web Services' \
  -o '[vsphere] VMWare vSphere / ESXi'
```

The `-o` flag (or `--option`, if you want to be verbose) is
required, and you generally want more than one.  The value you
pass to `-o` defines each successive menu entry that the user is
asked to choose from.  The text between square brackets is the
value to set the provided variable to if that option is chosen.
The rest of the value is a display name printed in the main menu.
The whitespace between the two is ignored, to aid in keeping hook
code clean and pretty.

Here's how that example above renders:

```
Which IaaS do you want to deploy on?
  1) Amazon Web Services
  2) VMWare vSphere / ESXi

Select choice >
```

If the user enters "2", the `$iaas` variable will get set to
`vsphere`.

The following flags are supported:

- **--label ...** - The label to display when asking for a choice.
  Defaults to 'Select choice'
- **--default ...** - A value to use when no selection is made.
  By default, the user will be asked again if they don't supply an
  answer.
- **--option ...** - described above.

A More Full Example
-------------------

Now that we know all about `prompt_for`, let's add in the rest of
our `new` hook, and ask the user if they want to supply their own
certificate or not.

We'll start with a boolean prompt, to see if they are interested.

```
prompt_for provide_cert boolean \
  'Do you want to provide your own TLS certificate for Vault?'
```

Next up, we ask them for that certificate, _but only if they said
yes!_

```
key=
cert=
if [[ $provide_cert == "true" ]]; then
  prompt_for key block \
    'Paste in the PEM-encoded contents of your TLS private key'
  prompt_for cert block \
    'Now, paste in the contents of the public certificate'
fi
```

Later on, when we're generating the environment YAML, we will
revisit the `$provide_cert` variable and optionally emit the
parameter definitions for the key and the cert:

```
  # this is inside the (...) > $root/$name.yml subshell
  if [[ $provide_cert == "true" ]]; then
    echo "  # You have chosen to provide your own TLS key/cert"
    echo "  # for Vault to use for the API.  Here it is:"
    echo "  #"
    echo "  provided_key: |"
    sed -e 's/^/    /' <<<"$key"
    echo
    echo "  provided_certificate: |"
    sed -e 's/^/    /' <<<"$cert"
  fi
```

Easy!


Securing Secret Parameters
--------------------------

Ideally, we never expose a users sensitive credentials by putting
them in the manifest directly.  Instead, things like the provided
TLS certificate and key should go in the Vault, and we should put
references to those Vault'ed secrets in the manifest.

Genesis has prompt types that do that, namely `secret-line` and
`secret-block`.  They work just like their non-secret
counterparts, except for two key differences:

  1. The values go in the vault
  2. The first argument to the `prompt_for` function is a relative
     path in the Vault, where you want the secret stored.

So, let's do that.  First, we'll put provided certificates in
Vault under "$prefix/provided-cert".

```
key=
cert=
if [[ $provide_cert == "true" ]]; then
  prompt_for "$prefix/provided-cert:key" secret-block \
    'Paste in the PEM-encoded contents of your TLS private key'
  prompt_for "$prefix/provided-cert:certificate" secret-block \
    'Now, paste in the contents of the public certificate'
fi
```

Then we reference the Vault path in the final environment file:

```
  # this is inside the (...) > $root/$name.yml subshell
  if [[ $provide_cert == "true" ]]; then
    echo "  # You have chosen to provide your own TLS key/cert"
    echo "  # for Vault to use for the API.  These are stored"
    echo "  # in the Vault (so meta!)"
    echo "  #"
    echo "  provided_key:         (( vault meta.vault \"/provided-cert:key\" ))"
    echo "  provided_certificate: (( vault meta.vault \"/provided-cert:certificate\" ))"
  fi
```

Easy, _and_ Secure!
