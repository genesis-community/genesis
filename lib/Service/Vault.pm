package Service::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;

use Genesis::UI;
use JSON::PP qw/decode_json/;
use UUID::Tiny ();

### Class Variables {{{
my (@all_vaults, $default_vault, $current_vault);
# }}}

### Class Methods {{{

# new - raw instantiation of a vault object {{{
sub new {
	my ($class, $url, $name, $verify, $namespace, $strongbox, $mount) = @_;
	$mount =~ s#^/*(.*[^/])/*$#/$1/# if $mount;
	return bless({
			url       => $url,
			name      => $name,
			verify    => $verify ? 1 : 0, # Cleans out JSON::Boolean types
			namespace => $namespace || '',
			strongbox => !defined($strongbox) || $strongbox ? 1 : 0, # defaults to true
			mount     => $mount || '/secret/',
			id        => sprintf("%s-%06d",$name,rand(1000000))
		}, $class);
}

# }}}
# create - return all vaults known to safe {{{
sub create {
  my $class = shift;
  bug 'Cannot directly instantiate a Genesis::Vault - use a derived class'
    if $class eq __PACKAGE__;
	# FIXME:  Should subclasses call this to add a created vault to the @all_vaults class property?
  bug "Expected $class to provide 'create' method, but it did not (or called SUPER)"
    if $class eq __PACKAGE__;
}

# }}}
# all_vaults - return all vaults known to safe {{{
sub all_vaults {
	my @available_vaults;
	my @targets = sort {$a->{name} cmp $b->{name}} @{
		read_json_from(run({env => {VAULT_ADDR => undef, SAFE_TARGET => undef}}, "safe targets --json"))
	};
	require Service::Vault::Local;
	require Service::Vault::Remote;
	for (@targets) {
		if (Service::Vault::Local->valid_local_vault($_->{name})) {
			push @available_vaults, (
				Service::Vault::Local->rebind($_->{name})
				|| Service::Vault::Local->create($_->{name})
			);
		} else {
			push @available_vaults, Service::Vault::Remote->new(@{$_}{qw(
				url name verify namespace strongbox mount
			)})
		}
	}
	return @available_vaults;
}

# }}}
# find - return vaults that match filter (defaults to all) {{{
sub find {
	my ($class, %filter) = @_;

	@all_vaults = all_vaults() unless @all_vaults; #TODO: is it that important to cache this?  Does it save much time?
	my @matches = @all_vaults;
	for my $quality (keys %filter) {
		@matches = grep {$_->{$quality} eq $filter{$quality}} @matches;
	}
	return @matches;
}

# }}}
# find_by_target - return all vaults matching url associated with specified target alias or url {{{
sub find_by_target {
	my ($class, $target) = @_;
	my ($url, @aliases) = _get_targets($target);
	return map {$class->find(name => $_)} @aliases;
}

# }}}
# default - return the default vault (targeted by system) {{{
sub default {
	my ($class,$refresh) = @_;
	unless ($default_vault && !$refresh) {
		my $json = read_json_from(run({env => {VAULT_ADDR => "", SAFE_TARGET => ""}},"safe target --json"));
		$default_vault = (Service::Vault->find(name => $json->{name}))[0];
	}
	return $default_vault;
}

# }}}
# current - return the last vault returned by attach, target, or rebind {{{
sub current {
	return $current_vault
}

# }}}
# clear_all - clear all cached data {{{
sub clear_all {
	for (@all_vaults) {
		delete($_->{_env});
	}
	@all_vaults=();
	$default_vault=undef;
	$current_vault=undef;
	return $_[0]; # chaining Service::Vault
}
# }}}
# find_single_match_or_bail - error out if there are duplicate vaults for a url {{{
sub find_single_match_or_bail {

	my ($class, $url, $current) = @_;
	my @matches =  $class->find(url => $url);

	bail(
		"\nMore than one target is specified for URL '%s'\n".
		"Please edit your ~/.saferc, and remove all but one of these:\n".
		"  - %s\n".
		"(or alter the URLs to be unique)",
		$url, join("\n  - ", map {
			$_->name eq ($current||'') ? "#G{".$_->name." (current)}" : "#y{".$_->name."}"
		} @matches)
	) if scalar(@matches) > 1;
	return $matches[0]
}

# }}}
# get_vault_from_descriptor - find unique vault from vault descriptor, or bail {{{
sub get_vault_from_descriptor {

	my ($class, $descriptor, $source) = @_;
	my $filter = $class->parse_vault_descriptor($descriptor, $source);
	my ($alias,$url) = delete(@{$filter}{qw/alias url domain port tls/});

	bail(
		"No url specified by vault descriptor"
	) unless $url;
	my @matches =  $class->find(url => $url, %$filter);

	# TODO: If none found, try by alias name?  Potential for mismatch though...

	if (@matches > 1) {
		my @named_matches = grep {$_->name eq $alias} @matches;
		@matches = @named_matches if @named_matches == 1;
	}

	return $matches[0] if @matches <= 1;

	# Error processing
	my ($alias_clause, $alias_msg) = ('','');
	if ($alias) {
		$alias_clause = ", (and none match the provided vault alias of '$alias').";
		$alias_msg = ", or add/modify the alias of the desired target to '$alias'"
	}

	my $default = $class->default->name;
	my $current = $ENV{GENESIS_TARGET_VAULT};

	bail(
		"\nMore than one target is specified for URL '%s'%s\n\n".
		"        Please edit your ~/.saferc, and remove all but one of these:\n".
		"        - %s\n".
		"        (or alter the URLs to be unique%s)",
		$url,$alias_clause, join("\n        - ", map {
			$_->name eq ($current||'')
				? "#G{".$_->name." (current)}"
				: $_->name eq ($default||'')
					? "#g{".$_->name." (default)}"
					: "#y{".$_->name."}"
		} @matches), $alias_msg
	);
}

# }}}
# parse_vault_descriptor - Get all the components of the genesis.vault {{{
sub parse_vault_descriptor {
	my ($class, $vault_info, $source) = @_;
	$source ||= 'genesis.vault';
	my ($url, $verify, $alias, $namespace, $strongbox, $tls, $domain, $port);
	$strongbox = 1;
	$vault_info =~ s/ as ([^ ]*) / / and $alias = $1;
	for my $clause (split(' ',$vault_info)) {
		if ($clause =~ /^(no-)?strongbox$/) {
			$strongbox = $1 ? 0 : 1;
		} elsif ($clause =~ /^(no-)?verify/) {
			$verify = $1 ? 0 : 1;
		} elsif ($clause =~ /^(http(s)?:\/\/([^:]*)(?::([0-9]+))?)(?:\/(.*))?$/) {
			$url = $1;
			$tls = ($2||'' eq 's');
			$domain = $3;
			$port = $4;
			$namespace = $5;
		} else {
			$ENV{GENESIS_TRACE}=1;
			dump_stack();
			bail(
				"Unknown clause in #G{$source}: '#Y{$clause}'\n".
				"Expected http#Cu{s}://<domain-or-ip>#Cu{:<port>}#Cu{/<namespace>} #Cu{as <alias>} #Cu{[no-]verify} #Cu{[no-]strongbox}\n".
				"#i{Values in }#Cui{cyan}#i{ are optional}"
			)
		}
	}
	bail(
		"Missing connect clause in #G{$source}\n".
		"Expected http#Cu{s}://<domain-or-ip>#Cu{:<port>}#Cu{/<namespace>} #Cu{as <alias>} #Cu{[no-]verify} #Cu{[no-]strongbox}\n".
		"#i{Values in }#Cui{cyan}#i{ are optional}"
	) unless $url;
	$verify = $tls unless defined($verify);

	return wantarray ? (
		$url, $verify, $namespace, $alias, $strongbox
	) : {
		url => $url,
		verify => $verify,
		alias => $alias,
		namespace => $namespace,
		strongbox => $strongbox,
		tls => $tls,
		domain => $domain,
		port => $port
	};
}

# }}}
# }}}

### Instance Methods {{{

# public accessors: url, name, verify, tls {{{
sub url        { $_[0]->{url};       }
sub name       { $_[0]->{name};      }
sub verify     { $_[0]->{verify};    }
sub namespace  { $_[0]->{namespace}; }
sub strongbox  { $_[0]->{strongbox}; }
sub tls        { $_[0]->{url} =~ "^https://"; }

#}}}
# connect_and_validate - connect to the vault and validate that its connected {{{
sub connect_and_validate {
	bug(
		"Expected %s to provide 'connect_and_validate' method, but it did not (or called SUPER)",
		ref($_[0])
	);
	# FIXME:  Should subclasses call this to set object as current?
}

# }}}
# authenticate - attempt to log in with credentials available in environment variables {{{
sub authenticate {
	bug(
		"Expected %s to provide 'authenticate' method, but it did not (or called SUPER)",
		ref($_[0])
	);
}

# }}}
# authenticated - returns true if authenticated {{{
sub authenticated {
	my $self = shift;
	delete($self->{_env}); # Force a fresh token retrieval
	return unless $self->token;
	my ($auth,$rc,$err) = read_json_from($self->query({stderr => '/dev/null'},'safe auth status --json'));
	return $rc == 0 && $auth->{valid};
}

# }}}
# initialized - returns true if initialized for Genesis {{{
sub initialized {
	my $self = shift;
	my $secrets_mount = $ENV{GENESIS_SECRETS_MOUNT} || $self->{mount};
	$self->has($secrets_mount.'handshake') || ($secrets_mount ne '/secret/' && $self->has('/secret/handshake'))
}

# }}}
# query - make safe calls against this vault {{{
sub query {
	my $self = shift;
	my $opts = ref($_[0]) eq "HASH" ? shift : {};
	my @cmd = @_;
	unshift(@cmd, 'safe') unless $cmd[0] eq 'safe' || $cmd[0] =~ /^safe /;
	$opts->{env} ||= {};
	$opts->{env}{DEBUG} = ""; # safe DEBUG is disruptive
	$opts->{env}{SAFE_TARGET} = $self->ref unless defined($opts->{env}{SAFE_TARGET});
	return run($opts, @cmd);
}

# }}}
# get - get a key or all keys under for a given path {{{
sub get {
	my ($self, $path, $key) = @_;
	if (defined($key)) {
		my ($out,$rc) = $self->query({redact_output => 1}, 'get', "$path:$key");
		return $out if $rc == 0;
		debug(
			"#R{[ERROR]} Could not read #C{%s:%s} from vault at #M{%s}",
			$path, $key,$self->{url}
		);
		return undef;
	}
	my ($json,$rc,$err) = read_json_from($self->query({stderr => 0, redact_output => 1}, 'export', $path));
	if ($rc || $err) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$err || '',$rc
		);
		return {};
	}
	$path =~ s/^\///; # Trim leading / as safe doesn't honour it
	return $json->{$path} if (ref($json) eq 'HASH');

	# Safe 1.1.0 is backwards compatible, but leaving this in for futureproofing
	if (ref($json) eq "ARRAY" and scalar(@$json) == 1) {
		if ($json->[0]{export_version}||0 == 2) {
			return $json->[0]{data}{$path}{versions}[-1]{value};
		}
	}
	bail "Safe version incompatibility - cannot export path $path";

}

# }}}
# set - write a secret to the vault (prompts for value if not given) {{{
sub set {
	my ($self, $path, $key, $value) = @_;
	if (defined($value)) {
		my ($out,$rc) = $self->query('set', $path, "${key}=${value}");
		bail(
			"Could not write #C{%s:%s} to vault at #M{%s}:\n%s",
			$path, $key,$self->{url},$out
		) unless $rc == 0;
		return $value;
	} else {
		# Interactive - you must supply the prompt before hand
		die_unless_controlling_terminal
			"#R{[ERROR]} Cannot interactively provide secrets unless in a controlling terminal - terminating!";
		my ($out,$rc) = $self->query({interactive => 1},'set', $path, $key);
		bail(
			"Could not write #C{%s:%s} to vault at #M{%s}",
			$path, $key,$self->{url}
		) unless $rc == 0;
		return $self->get($path,$key);
	}
}

# }}}
# has - return true if vault has given key {{{
sub has {
	my ($self, $path, $key) = @_;
	return $self->query({ passfail => 1 }, 'exists', defined($key) ? "$path:$key" : $path);
}

# }}}
# paths - return all paths found under the given prefixes (or all if no prefix given) {{{
sub paths {
	my ($self, @prefixes) = @_;

	# TODO: Once safe stops returning invalid pathts, the following will work:
	# return lines($self->query('paths', @prefixes));
	# instead, we have to do this less efficient routine
	return lines($self->query('paths')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', $prefix));
		if (scalar(@paths) == 1 && $paths[0] eq $prefix) {
			next unless $self->has($prefix);
		}
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# keys - return all path:key pairs under the given prefixes (or all if no prefix given) {{{
sub keys {
	my ($self, @prefixes) = @_;
	return lines($self->query('paths','--keys')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', '--keys', $prefix));
		next if (scalar(@paths) == 1 && $paths[0] eq $prefix);
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# status - returns status of vault: sealed, unreachable, unauthenticated, uninitialized or ok {{{
sub status {
	my $self = shift;

	# See if the url is reachable to start with
	$self->url =~ qr(^http(s?)://(.*?)(?::([0-9]*))?$) or
		bail("Invalid vault target URL #C{%s}: expecting http(s)://ip-or-domain(:port)", $self->url);
	my $ip = $2;
	my $port = $3 || ($1 eq "s" ? 443 : 80);
	my $status = tcp_listening($ip,$port);
	return "unreachable - $status" unless $status eq 'ok';

	my ($out,$rc) = $self->query({stderr => "&1"}, "vault", "status");
	if ($rc != 0) {
		$out =~ /exit status ([0-9])/;
		return "sealed" if $1 == 2;
		return "unreachable";
	}

	return "unauthenticated" unless $self->authenticated;
	return "uninitialized" unless $self->initialized;
	return "ok"
}

# }}}
# env - return the environment variables needed to directly access the vault {{{
sub env {
	my $self = shift;
	unless (defined $self->{_env}) {
		$self->{_env} = read_json_from(
			run({
					stderr =>'/dev/null',
					env => {SAFE_TARGET => $self->ref }
				},'safe', 'env', '--json')
		);
		$self->{_env}{VAULT_SKIP_VERIFY} ||= "";
		# die on missing VAULT_ADDR env?
	}
	return $self->{_env};
}

# }}}
# token - the authentication token for the active vault {{{
sub token {
	my $self = shift;
	return $self->env->{VAULT_TOKEN};
}

# }}}
# ref - the reference to be used when identifying the vault (name or url) {{{
sub ref {
	my $self = shift;
	return $self->{$self->{ref_by} || 'url'};
}

# }}}
# ref_by_name - use the name of the vault as its reference (legacy mode) {{{
sub ref_by_name {
	$_[0]->{ref_by} = 'name';
	$_[0];
}
# }}}
# build_descriptor - builds a descriptor for the current vault {{{
sub build_descriptor {
	my ($self) = @_;
	my $descriptor = $self->url;
	$descriptor .= ("/".$self->namespace) if $self->namespace;
	$descriptor .= " as ".$self->name;
	$descriptor .= " no-verify" if $self->tls && !$self->verify;
	$descriptor .= " no-strongbox" unless $self->strongbox;
	return $descriptor;
}

# }}}
# set_as_current - set this vault as the current Genesis vault {{{
sub set_as_current {
	$current_vault = shift;
}
sub is_current {
  $current_vault && $current_vault->{id} eq $_[0]->{id};
}

# }}}
# }}}

### Private helper functions {{{

# _target_is_url - determine if target is in valid URL form {{{
sub _target_is_url {
	my $target = lc(shift);
	return 0 unless $target =~ qr(^https?://([^:/]+)(?::([0-9]+))?$);
	return 0 if $2 && $2 > 65535;
	my @comp = split(/\./, $1);
	return 1 if scalar(@comp) == 4 && scalar(grep {$_ =~ /^[0-9]+$/ && $_ >=0 && $_ < 256} @comp) == 4;
	return 1 if scalar(grep {$_ !~ /[a-z0-9]([-_0-9a-z]*[a-z0-9])*/} @comp) == 0;
	return 0;
}

# }}}
# _get_targets - find all matching safe targets for the provided name or url {{{
sub _get_targets {
	my $target = shift;
	unless (_target_is_url($target)) {
		my $target_vault = (Service::Vault->find(name => $target, @_))[0];
		return (undef) unless $target_vault;
		$target = $target_vault->{url};
	}
	my @names = map {$_->{name}} Service::Vault->find(url => $target, @_);
	return ($target, @names);
}
# }}}
# }}}
1;

=head1 NAME

Service::Vault

=head1 DESCRIPTION

This module provides utilities for interacting with a Vault through safe.

=head1 Class Methods

=head2 new($url,$name,$verify)

Returns a blessed Service::Vault object based on the URL, target name and TLS verify values provided.

B<NOTE:> This should not be called directly, as it provides no error checking or validations.

=head2 target($target, %opts)

Returns a C<Service::Vault> object representing the vault at the given target
or presents the user with an interactive prompt to specify a target.  This is
intended to be used when setting up a deployment repo for the first time, or
selecting a new vault for an existing deployment repo.

In the case that the target is passed in, the target will be validated to
ensure that it is known, a url or alias and that its url is unique (not being
used by any other aliases); A C<Service::Vault> object for that target is
returned if it is valid, otherwise, an error will be raised.

In the case that the target is not passed in, all unique-url aliases will be
presented for selection, with the current system target being shown as a
default selection.  If there are aliases that share urls, a warning will be
presented to the user that some invalid targets are not shown due to that.
The user then enters the number corresponding to the desired target, and a
C<Service::Vault> object corresponding to that slection is returned.  This
requires that the caller is in a controlling terminal, otherwise the program
will terminate.

C<%opts> can be the following values:

=over

=item default_vault

A C<Service::Vault> that will be used as the default
vault selection in the interactive prompt.  If not provided, the current system
target vault will be used.  Has no effect when not in interactive mode.

=back

In either cases, the target will be validated that it is reachable, authorized
and ready to be used, and will set that vault as the C<current> vault for the
class.

=head2 attach($url, $insecure)

Returns a C<Service::Vault> object for the given url according to the user's
.saferc file.

This will result in an error if the url is not known in the .saferc or if it
is not unique to a single alias, as well as if the url is not a valid url.

The C<insecure> does not matter for the attach, but does change the error
output for describing how to add the target to the local safe configuration if
it is missing.

=head2 rebind

This is used to rebind to the previous vault when in a callback from a Genesis-
run hook.  It uses the C<GENESIS_TARGET_VAULT> environment variable that is set
prior to running a hook, and only ensures that the vault is known to the system.

=head2 find(%conditions)

Without any conditions, this will return all system-defined safe targets as
Service::Vault objects.  Specifying hash elemements of the property => value
filters the selection to those that have that property value (compared as string)
Valid properties are C<url>, C<name>, C<tls> and C<verify>.

=head2 find_by_target($alias_or_url)

This will return all Vaults that use the same url as the given alias or url.

=head2 default

This will return the Vault that is the set target of the system, or null if
there is no current system target.

=head2 current

This will return the Vault that was the last Vault targeted by Service::Vault
methods of target, attach or rebind, or by the explicit set_as_current method
on a Vault object.

=head2 clear_all

This method removes all cached Vault objects and the C<current> and C<default>
values.  Though mainly used for providing a clean slate for testing, it could
also be useful if the system's safe configuration changes and those changes need
to be picked up by Genesis during a run.

=head1 Instance Methods

Each C<Service::Vault> object is composed of the properties of url, its name
(alias) as it is known on the local system, and its verify (binary opposite of
skip-ssl-validation).  While these properties can be queried directly, it is
better to use the accessor methods by the same name

=head2 url

Returns the url for the Vault object, in the form of:
C<schema://host_name_or_ip:port>

The :port is optional, and is understood to be 80 for http schema or 443 for
https.

=head2 name

Returns the name (aka alias) of the vault as it is known on the local system.
Because the same Vault target url may be known by a different name on each
system, the use of the alias is not considered an precise identifier for a
Vault, and only used for convenience in display output or specifying a target
initially.

=head2 verify

Returns a boolean true if the vault target's certificate will be validated
when it is connected, or false if not.  Only applicable to https urls, though
http will default to true.

=head2 tls

Convenience method to check if using https (true) or http (false) rather than
having to substring or regex the url.

=head2 query

Allows caller to pass a generic query to the selected vault.  The user can
specify anything that would normally come after `safe ...` on the command line,
but not the -T <target> option will NOT have any effect.

This can take the same arguments and returns the same structure that a
C<Genesis::run> method would, with two caveats:

=over

=item *

Setting the environment variable SAFE_TARGET will get overwritten with the url
of the Vault object being operated on.

=item *

Setting the DEBUG environment variable will get unset because it is disruptive
to the call.  If you want to see the call being made so you can debug it, run
the Genesis command with -T or set the GENESIS_TRACE variable to 1

=back

=head2 get($path[, $key])

Return the string of the given path and key, or return the entire content under
the given path if no key is given.  The path does not have to be an end node
that contains keys; it can be a branch path, in which case all the sub-paths
and their key:value pairs will be returned.

=head2 set($path, $key[, $value])

If a value is specified, it will set that value (as a string) to the given key
on the specified path.  If no value is provided, an interactive mode will be
started where the user will be prompted to enter the value.  This will be
'dotted' out on the screen, and the user will have to enter the same value
again to confirm the correctness of their entry.

=head2 has($path[, $key])

Returns true if the vault contains the path and optionally the key if given.
Equivalent to C<safe exists $path> or C<safe exists $path:$key> as appropriate.

=head2 paths([@prefixes])

Returns a list of all paths in the vault if no prefix was specified, or all
paths that can be found under the specified prefixes.  If you ask for
overlapping prefixes, paths that match multiple prefixes will be returned
multiple times.

Note that this will only return node paths (paths that contain keys on their
last path segment, so if a vault only contains
B<secret/this/is/my/long/path:key> and you asked for paths, it would only
return that entry, not each partial path.

=head2 keys

Similar to C<paths> above, but also includes the B<:key> suffix for each key
under the matching paths.

=head2 status

Returns the status of the vault.  This is a string value that can be one of the
following:

=over

=item unreachable

This means that the vault url or port is not responding to connection attempts.
This may be because the C<vault> executable has stopped working, or due to
networking issue (e.g.: VPN not connected)

=item unauthenticated

This means that the vault is responding, but the local safe token has expired
or not been set.  Run C<safe auth ...> to connect, then try the command again.

=item sealed

The vault is sealed, and must be unsealed by the administrator before you can
access it.

=item uninitialized

The vault is responding and authenticated, but does not look like it was
correctly initialized with safe.

This may be a basic vault that was stood up manually -- to resolve this, simply
run `safe set secret/handshake knock=knock` once you're sure your talking to
the correct vault.  If you are using a different secret mount in your
environments, replace '/secret/' with the same mount that your environments
use.

=item ok

The vault is operating normally and the user is authenticated.

=back

=head2 env

This returns a hash of the environment variable names and values for
configuring the vault for things that use the basic Hashicorp vault environment
variables to target a vault, such as C<spruce>.  This can be fed directly into
the C<Genesis::run> commands C<env> option.

=head2 token

The authentication token for the vault, as stored in the C<.saferc> file.

=head2 set_as_current

Set the vault object as the current vault object used by this run of Genesis.
This is sometimes needed when dealing with legacy aspects of genesis
(pipelines, params from kit.yml) where there is no passing in of the C<Env> or
C<Top> object.

This is automatically called by C<target>, C<attach> and C<rebind> and
generally doesn't need to be manually set, but there are a few circumstances
that it may be necessary, so this was exposed as a public method.

=cut

# vim: fdm=marker:foldlevel=1:noet
