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
# vim: fdm=marker:foldlevel=1:noet
