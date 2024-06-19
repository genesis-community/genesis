package Service::Vault::Remote;
use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;

use Genesis::UI;
use JSON::PP qw/decode_json/;
use UUID::Tiny ();

use base 'Service::Vault';

### Class Variables {{{
my (@all_vaults, $default_vault, $current_vault);
# }}}

### Class Methods {{{

# create - create a new safe target and target it {{{
sub create {
	my ($class, $url, $name, %opts) = @_;

	my $default = $class->default(1);

	my @cmd = ('safe', 'target', $url, $name);
	push(@cmd, '-k') if $opts{skip_verify};
	push(@cmd, '-n', $opts{namespace}) if $opts{namespace};
	push(@cmd, '--no-strongbox') if $opts{no_strongbox};
	my ($out,$rc,$err) = run({stderr => 0, env => {VAULT_ADDR => "", SAFE_TARGET => ""}}, @cmd);
	run('safe','target',$default->{name}) if $default; # restore original system target if there was one
	bail(
		"Could not create new Safe target #C{%s} pointing at #M{%s}:\n %s",
		$name, $url, $err
	) if $rc;
	my $vault = $class->new($url, $name, !$opts{skip_verify}, $opts{namespace}, !$opts{no_strongbox}, $opts{mount});
	for (0..scalar(@all_vaults)-1) {
		if ($all_vaults[$_]->{name} eq $name) {
			$all_vaults[$_] = $vault;
			return $vault;
		}
	}
	push(@all_vaults, $vault);
	return $vault;
}

# }}}
# target - builder for vault based on locally available vaults {{{
sub target {
	my ($class,$target,%opts) = @_;

	$opts{default_vault} ||= $class->default;

	my $url;
	if ($target) {
		($url, my @targets) = Service::Vault::_get_targets($target);
		if (scalar(@targets) <1) {
			bail "Safe target \"#M{%s}\" not found.  Please create it".
					 "and authorize against it before re-attempting this command.",
					 $target;
		}
		if (scalar(@targets) >1) {
			# TODO: check if one of the returned values matches the alias
			bail "Multiple safe targets use url #M{%s}:\n%s\n".
					 "\n".
					 "Your ~/.saferc file cannot have more than one target for the ".
					 "given url.  Please remove any duplicate targets before ".
					 "re-attempting this command.",
					 $url, join("", map {" - #C{$_}\n"} @targets);
		}
	} else {

		die_unless_controlling_terminal
			"Cannot interactively select vault unless in a controlling terminal - terminating!";

		my $w = (sort {$b<=>$a} map {length($_->{name})} $class->find)[0];

		my (%uses,@labels,@choices);
		$uses{$_->{url}}++ for $class->find;
		for ($class->find) {
			next unless $uses{$_->{url}} == 1;
			push(@choices, $_->{url});
			push(@labels, [csprintf(
			"#%s{%-*.*s}   #R{%-10.10s} #%s{%s}",
			  $_->{name} eq $opts{default_vault}->{name} ? "G" : "-",
			     $w, $w, $_->{name},
			                  $_->{url} =~ /^https/ ? ($_->{verify} ? "" : "(noverify)") : "(insecure)",
			                             $_->{name} eq $opts{default_vault}->{name} ? "Y" : "-",
			                                $_->{url}
			),$_->{name}]);
		}

		my $msg = csprintf("#u{Select Vault:}\n");
		my @invalid_urls = grep {$uses{$_} > 1} keys(%uses);

		if (scalar(@invalid_urls)) {
			$msg .= csprintf("\n".
				"#Y{Note:} One or more vault targets have been omitted because they are alias for\n".
				"      the same URL, which is incompatible with Genesis's distributed model.\n".
				"      If you need one of the omitted targets, please ensure there is only one\n".
				"      target alias that uses its URL.\n");
		}

		bail("There are no valid vault targets found on this system.")
			unless scalar(@choices);

		$url = prompt_for_choice(
			$msg,
			\@choices,
			$uses{$opts{default_vault}->{url}} == 1 ? $opts{default_vault}->{url} : undef,
			\@labels
		)
	}

	my $vault = ($class->find(url => $url))[0];
	return $vault->connect_and_validate()
}

# }}}
# attach - builder for vault based on loaded environment {{{
sub attach {
	my ($class, %opts) = @_;

	for my $opt (keys %opts) {
		# Allow vault options to be specified by ENV variables.
		my $value = $opts{$opt};
		next unless defined $value;
		$opts{$opt} = $ENV{substr($value,1)} if substr($value,0,1) eq '$';
	}

	$opts{tls} = $opts{url} =~ /https:\/\// ? 1 : 0 if $opts{url} && !defined($opts{tls});

	my $url = delete($opts{url});
	my $alias = delete($opts{alias});
	my $allow_no_vault = $opts{no_vault};
	my $silent = $opts{silent};

	bail "No vault target specified"
		unless $url;
	bail "Expecting vault target '$url' to be a url"
		unless Service::Vault::_target_is_url($url);

	my %filter = (url => $url);
	$filter{verify} = (($opts{tls} && $opts{verify}) ? 1 : 0) if $opts{tls};
	for (qw/namespace strongbox/) {
		$filter{$_} = $opts{$_} if defined($opts{$_});
	}

	my @targets = Service::Vault->find(%filter);
	if (scalar(@targets) <1) {
		my @close_targets = Service::Vault->find(url => $filter{url});
		if (@close_targets) {
			my $msg = "Could not find matching safe target, but the following are similar:\n";
			for my $target (@close_targets) {
				$msg .= "\nAlias:     '$target->{name}'\n";
				for my $property (qw/url namespace strongbox verify/) { # TODO: support name and mount in filter
					$msg .= sprintf("%-11s'%s'", ucfirst($property.":"),$target->{$property});
					$msg .= " (expected '$filter{$property}')" if ($filter{$property} ne $target->{$property});
					$msg .= "\n";
				}
			}
			bail $msg."\nAlter your ~/.saferc or .genesis/config to match, or add a matching target.\n";
		} else {
			# TODO: If alias and url was given, and in a controlling terminal, create safe target
			return if $allow_no_vault;
			bail "Safe target for #M{%s} not found.  Please run\n\n".
					 "  #G{safe target <name> \"%s\"%s}\n\n".
					 "then authenticate against it using the correct auth method before ".
					 "re-attempting this command.",
					 $url, $url,($opts{verify}?"":" -k");
		}
	}
	if (scalar(@targets) >1) {
		my ($named_target) = grep {$_->name eq $alias} @targets;
		if ($named_target) {
			@targets = ($named_target)
		} else {
			bail(
				"Multiple safe targets found for #M{%s}:\n%s\n".
				"\n".
				"Your ~/.saferc file cannot have more than one target for the given ".
				"url, namespace, insecure or strongbox combination.  If you don't, it ".
				"may be that your selected secrets provider is out of date - please ".
				"rerun #G{genesis sp -i}\n".
				"\n".
				"Please remove any duplicate targets before re-attempting this command.",
				$url, join("", map {" - #C{$_->name}\n"} @targets)
			);
		}
	}
	return $targets[0]->connect_and_validate($opts{silent});
}

# }}}
# rebind - builder for rebinding to a previously selected vault (for callbacks) {{{
# TODO: Bind to alias, which encapuslates all the namespace, validation, strongbox, url, etc...
sub rebind {
	# Special builder with less checking for callback support
	my ($class) = @_;

	bail("Cannot rebind to vault in callback due to missing environment variables!")
		unless $ENV{GENESIS_TARGET_VAULT};

	my $vault;
	if (is_valid_uri($ENV{GENESIS_TARGET_VAULT})) {
		$vault = ($class->find(url => $ENV{GENESIS_TARGET_VAULT}))[0];
		bail("Cannot rebind to vault at address '$ENV{GENESIS_TARGET_VAULT}` - not found in .saferc")
			unless $vault;
		trace "Rebinding to $ENV{GENESIS_TARGET_VAULT}: Matches %s", $vault && $vault->{name} || "<undef>";
	} else {
		# Check if its a named vault and if it matches the default (legacy mode)
		if ($ENV{GENESIS_TARGET_VAULT} eq $class->default->{name}) {
			$vault = $class->default()->ref_by_name();
			trace "Rebinding to default vault `$ENV{GENESIS_TARGET_VAULT}` (legacy mode)";
		}
	}
	return unless $vault;
	return $vault->set_as_current;
}

# }}}
# find - return vaults that match filter (defaults to all) {{{
sub find {
	my ($class, %filter) = @_;
	return grep {ref($_) eq $class} $class->SUPER::find(%filter);
}

# }}}
# }}}

### Instance Methods {{{

# connect_and_validate - connect to the vault and validate that its connected {{{
sub connect_and_validate {
	my ($self, $silent) = @_;
	unless ($self->is_current) {
		my $log_id = info({pending => 1, delay => 2000 }, # don't show for 2 seconds (NYI)
			"\n#yi{Verifying availability of vault '%s' (%s)...}",
			$self->name, $self->url
		) unless in_callback || under_test || $silent;
		my $status = $self->status;
		if ($status eq 'unauthenticated') {
			$self->authenticate;
			$status = $self->initialized ? 'ok' : 'uninitialized';
		}
		# TODO: support delayed output:
		#   Implement delay flag to logs
		#   - Print logs after delay specified
		#   - cancel_delayed_log(log_id) clear logs before delay expires by log_id
		#   - have has_been_logged(log_id) for checking
		#   - clear_delay(log_id) clears delay and logs entry
		#
		#   Issues: Perl can only handle one timeout (via alarm) at the same time
		#   - see https://metacpan.org/pod/Time::Out
		#
		#  As it applies here:
		#    if the $log_id hasn't been logged, cancel it and move on if ok, print
		#    it immediately and add bad status
		#    if it has been logged, just do what it currently does
		#
		#  Motive:  Don't print out the vault test if it quickly comes back, but
		#  if it takes a long time, let user's know what its trying to do...
		#
		info ("#%s{%s}", $status eq "ok"?"G":"R", $status)
			unless in_callback || under_test || $silent;
		debug "Vault status: $status";
		bail("Could not connect to vault%s",
			(in_callback || under_test || $silent) ? sprintf(" '%s' (%s): status is %s)", $self->name, $self->url,$status):""
		) unless $status eq "ok";
	}
	return $self->set_as_current;
}

# }}}
# authenticate - attempt to log in with credentials available in environment variables {{{
sub authenticate {
	my $self = shift;
	my $ref = $self->ref();
	my $auth_types = [
		{method => 'approle',  label => "AppRole",                     vars => [qw/VAULT_ROLE_ID VAULT_SECRET_ID/]},
		{method => 'token',    label => "Vault Token",                 vars => [qw/VAULT_AUTH_TOKEN/]},
		{method => 'userpass', label => "Username/Password",           vars => [qw/VAULT_USERNAME VAULT_PASSWORD/]},
		{method => 'github',   label => "Github Peronal Access Token", vars => [qw/VAULT_GITHUB_TOKEN/]},
	];

	return $self if $self->authenticated;
	my %failed;
	for my $auth (@$auth_types) {
		my @vars = @{$auth->{vars}};
		if (scalar(grep {$ENV{$_}} @vars) == scalar(@vars)) {
			debug "Attempting to authenticate with $auth->{label} to #M{$ref} vault";
			my ($out, $rc) = $self->query(
				'safe auth ${1} < <(echo "$2")', $auth->{method}, join("\n", map {$ENV{$_}} @vars)
			);
			return $self if $self->authenticated;
			debug "Authentication with $auth->{label} to #M{$ref} vault failed!";
			$failed{$auth->{method}} = 1;
		}
	}

	# Last chance, check if we're already authenticated; otherwise bail.
	# This also forces a update to the token, so we don't have to explicitly do that here.
	return $self if $self->authenticated;
	bail(
		"Could not successfully authenticate against #M{$ref} vault with #C{safe}.\n\n".
		"Genesis can automatically authenticate with safe in the following ways:\n".
		join("", map {
			my $a=$_;
			sprintf(
				"        - #G{%s}, supplied by %s%s\n",
				$a->{label},
				join(' and ', map {"#y{\$$_}"} @{$a->{vars}}),
				($failed{$a->{method}}) ? " #R{[present, but failed]}" : ""
			)
		} @{$auth_types})
	);
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
