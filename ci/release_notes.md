# New Feature: Kit Providers

Until now, you could only use the kits that were provided by the
`genesis_community` organization on GitHub, or by creating dev kits yourself.
This release allows you to specify any GitHub org as a kit provider.

## Creating a new repo with an alternative kit provider:

```
genesis init --kit-provider        github \
             --kit-provider-org    myproject \
             --kit-provider-domain github.mycorp.com \
             --kit-provider-tls    skip\
             --kit-provider-name   "Our Custom Kit Provider" \
             --kit                 my-awesome-kit
```

There are further options, which can be shown using --help.

## Showing current kit provider:

```
genesis kit-provider

Collecting informaion on current kit provider for concourse deployment at ./work/concourse-deployments ...done.

         Type: github

         Name: Our Custom Kit Provider
       Domain: github.mycorp.com
          Org: myproject
      Use TLS: skip

       Status: ok

         Kits: my-awesome-kit
               another-kit

```

## Changing kit provider on existing repo:

```
genesis kit-provider --default
genesis kit-provider --kit-provider genesis-community
```

Either of these will set the kit provider to the default Genesis Community kit
provider.

```
genesis kit-provider --kit-provider github [... rest of github-specific options]
```

You can also change it to another github org as its kit provider using the
above.

Note:  You can't just change one option to have it update just that property
-- you must set all the provider-specific options to update the provider
information.  Refer to the help output (-h|--help) for details on what options
are expected.

# Removed Freature: Genesis v1 Support

This is a breaking change for anyone who still uses Genesis v1 repositories.

When Genesis v2 came out, it included full backwards compatibility with
Genesis v1 repositories, which were very different in structure and behaviour.
As v1 was a Bash script, and v2 was built in Perl, this was accomplished by
simply embedding the Bash script in the Perl (as data up to v2.4.x, and as a
separate file after that) and passing control to that script when a v1 repo
was detected.

However, with BOSH no longer supporting v1-style manifests, it seemed a good
time to remove this obsolete funtionality and shrink down the package.  If you
still need this, any version from v2.5.x or v2.6.x will work for you, as the
v1 embedded in those versions haven't changed.
