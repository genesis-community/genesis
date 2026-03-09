package Service::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term qw/csprintf/;

use Genesis::UI;
use JSON::PP qw/decode_json/;
use Time::HiRes qw/gettimeofday/;
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
# set_default - set the default vault (targeted by system) {{{
sub set_default {
	my ($class, $vault) = @_;
	my ($out, $rc, $err) = run({env => {VAULT_ADDR => "", SAFE_TARGET => ""}},"safe", "target", $vault->name);
	bail(
		"Could not set default vault to #C{%s}:\n%s",
		$vault->name, $err
	) unless $rc == 0;
	return $vault;
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
# TODO: Validate dependencies with output that is compatible wth
# Genesis::Command::check_reqs
# }}}

### Instance Methods {{{

# public accessors: url, name, verify, namespace, strongbox, tls {{{
sub url {
	$_[0]->{url};
}

sub name {
	$_[0]->{name};
}

sub verify {
	$_[0]->{verify};
}

sub namespace {
	$_[0]->{namespace};
}

sub strongbox {
	$_[0]->{strongbox};
}

sub tls {
	$_[0]->{url} =~ "^https://";
}

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
	$opts->{stderr} = 0 unless defined($opts->{stderr});
	return run($opts, @cmd);
}

# }}}
# get - get a key or all keys under for a given path {{{
sub get {
	my ($self, $path, $key) = @_;
	$path =~ s/\/{2,}/\//g; # Clean up any double slashes from joins
	if (!defined($key) && $path =~ /:/) {
		($path, $key) = $path =~ m/^(.*?)(?::([^:]*))?$/;
	}
	if (defined($key)) {
		my ($out,$rc) = $self->query({redact_output => 1}, 'get', "$path:$key");
		return $out if $rc == 0;
		debug(
			"#R{[ERROR]} Could not read #C{%s:%s} from vault at #M{%s}",
			$path, $key,$self->{url}
		);
		return undef;
	}
	my $start = gettimeofday();
	my ($yaml,$rc,$err) = $self->query({stderr => 0, redact_output => 1}, 'get', $path);
	if ($rc || $err) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$err || '',$rc
		);
		return {};
	}
	my $values = load_yaml($yaml);
	bail(
		"Expected #C{%s} to return a hash of key/value pairs, but got a %s",
		$path, ref($values)
	) unless ref($values) eq 'HASH';
	trace(
		"Exported %s key/value pairs from #C{%s} in vault at #M{%s} in %.3f seconds",
		scalar(CORE::keys %$values), $path, $self->{url}, gettimeofday() - $start
	);
	return $values;
}

# }}}
# get_path - get all the keys under a given path, including subpaths {{{
sub get_path {
	my ($self, $path) = @_;
	$path =~ s{(^/*|/*$)}{}; # Trim preceeding and trailing / as safe doesn't honour it
	my ($data,$rc,$err) = read_json_from($self->query({stderr => 0, redact_output => 1}, 'export', $path));
	if ($rc || $err) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$err || '',$rc
		);
		return {};
	}

	my $results = {};
	for my $subpath (sort keys %$data) {
		if ($subpath eq $path) {
			$results = delete($data->{$subpath}{__flattened__})
				? Genesis::unflatten($data->{$subpath})
				: $data->{$subpath};
			next;
		}
		my @path_bits = split('/',substr($subpath,length($path)+1));
		my $refobj = $results;
		$refobj = $refobj->{shift @path_bits} //= {} while @path_bits > 1;
		$refobj->{$path_bits[0]} = delete($data->{$subpath}{__flattened__})
			? Genesis::unflatten($data->{$subpath})
			: $data->{$subpath};
	}
	return $results;
}
# }}}
# set - write a secret to the vault (prompts for value if not given) {{{
sub set {
	my ($self, $path, $key, $value) = @_;
	$path =~ s/\/{2,}/\//g; # Clean up any double slashes from joins
	# FIXME: If the path contains a :<key>, then the content of $key
	#        should be moved to $value and $path and $key should be split
	#        from the path.  This allows users to call set with an already
	#        joined path:key pair.  This should not impact existing code
	#        because currently passing in a path:key pair results in an error.
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
# clear - remove all keys under a given path {{{
sub clear {
	my ($self, $path, $recursive) = @_;
	my ($out,$rc,$err) = ('',0,'');
	if ($recursive) {
		debug("Clearing #C{%s} and all subpaths in vault at #M{%s}", $path, $self->{url});
		($out,$rc,$err) = $self->query('rm', '-rf', $path);
	} elsif (!$self->has($path)) {
		debug("Path #C{%s} does not exist in vault at #M{%s} - no need to clear", $path, $self->{url});
		return;
	} else {
		debug("Clearing #C{%s} in vault at #M{%s}", $path, $self->{url});
		($out,$rc,$err) = $self->query('rm', '-f', $path);
	}
	bail(
		"Could not clear #C{%s} in vault at #M{%s}:\n%s",
		$path,$self->{url},$out.$err
	) unless $rc == 0;
	return 1;
}

# set_path - writes a set of key value pairs to the vault {{{
sub set_path {
	my ($self, $path, $data, %opts) = @_;

	my $flatten = $opts{flatten} // 0;
	my $clear = $opts{clear} // 0;
	if ($flatten) {
		$data = Genesis::flatten({},'',$data);
		$data->{__flattened__} = JSON::PP::true;
	}

	$self->clear($path, !$flatten) if ($clear);

	my @set_data = ();
	for my $key (sort keys %$data) {
		my $value = $data->{$key};

		# Skip empty containers from flatten() - vault cannot store refs
		if (ref($value) eq 'HASH') {
			next if keys %$value == 0;  # Skip empty hashes
			$self->set_path("$path/$key", $value);
			next;
		}

		if (ref($value) eq 'ARRAY') {
			next if @$value == 0;  # Skip empty arrays
			for my $i (0..$#{$value}) {
				if (ref($value->[$i]) eq 'HASH') {
					$self->set_path("$path/$key/$i", $value->[$i]);
				} else {
					push(@set_data, "${key}[${i}]=$value->[$i]");
				}
			}
			next;  # Don't fall through to scalar handling
		}

		push(@set_data, "$key=$value");

		# make sure the command isn't too long (<900 characters)
		if (length(join(' ', @set_data)) > 900) {
			my @new_set_data = pop(@set_data);
			my ($out,$rc) = $self->query('set', $path, @set_data);
			bail(
				"Could not write #C{%s} to vault at #M{%s}:\n%s",
				$path,$self->{url},$out
			) unless $rc == 0;
			@set_data = @new_set_data;
		}
	}

  return $data unless scalar(@set_data);
	my ($out,$rc) = $self->query('set', $path, @set_data);
	bail(
		"Could not write #C{%s} to vault at #M{%s}:\n%s",
		$path,$self->{url},$out
	) unless $rc == 0;
	return $data;
}

# }}}
# has - return true if vault has given key {{{
sub has {
	my ($self, $path, $key) = @_;
	$path =~ s/\/{2,}/\//g; # Clean up any double slashes from joins
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
		if ($out =~ /More than one target for Vault at '(.*)'/) {
			return "ambiguous - multiple targets for $1";
		}
		$out =~ /exit status ([0-9])/;
		return "sealed" if $1//0 == 2;
		return "unreachable";
	}

	return "unauthenticated" unless $self->authenticated;
	return "uninitialized" unless $self->initialized;
	return "ok"
}

# }}}
# token_info - return the token information for the active user token {{{
sub token_info {
	my $self = shift;
	my ($out,$rc, $err) = $self->query('vault', 'token', 'lookup', '-format=json');
	return read_json_from($out) if $rc == 0;
	debug(
		"#R{[ERROR]} Could not get token information from vault at #M{%s}",
		$self->{url}
	);
	return {};
}

# }}}
# sub user - return the user information for the active user token {{{
sub user {
	my $self = shift;
	my $token_info = $self->token_info;
	return $token_info->{data}{meta}{username} || $token_info->{data}{display_name};
}

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
		# Explicitly override any existing SAFE_TARGET
		$self->{_env}{SAFE_TARGET} = $self->{_env}{VAULT_ADDR};
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
# fetch_unseal_keys - fetch and store unseal keys for post-deploy unsealing {{{
sub fetch_unseal_keys {
	my ($self, $env) = @_;

	# Clear any previously stored keys
	my $secrets_mount = $env->secrets_mount;
	my $keys_path = "${secrets_mount}vault/seal/keys";
	$self->{unseal_keys} = [values(($self->get($keys_path)//{})->%*)];
	my $key_count = scalar(@{$self->{unseal_keys}});

	# Check if the keys path exists
	return (0, "Vault unseal keys not found at #C{$keys_path}")
		unless ($key_count);

	return (0, "Insufficient unseal keys found at #C{$keys_path}: Need at least 3, found $key_count")
		unless $key_count >= 3;

	return (1, sprintf("Successfully fetched vault unseal keys from #C{%s}", $keys_path));
}

# }}}
# unseal - unseal the vault using stored unseal keys {{{
sub unseal {
	my $self = shift;

	# Check if we have stored unseal keys
	unless ($self->{unseal_keys} && @{$self->{unseal_keys}}) {
		return ("No unseal keys available", 1, "fetch_unseal_keys() must be called first");
	}

	# Check if we have at least 3 keys (required by safe unseal)
	unless (@{$self->{unseal_keys}} >= 3) {
		return ("Insufficient unseal keys available", 1, sprintf("safe unseal requires 3 keys, but only %d available", scalar(@{$self->{unseal_keys}})));
	}

	# Use safe unseal which unseals all vault instances in the cluster
	# safe unseal expects exactly 3 keys, so take the first 3
	my @keys_to_use = @{$self->{unseal_keys}}[0..2];
	my $keys_input = join("\n", @keys_to_use) . "\n";

	# Use the stdin option with query to pass keys to safe unseal
	my ($out, $rc);
	my ($tries, $max_tries) = (0, 3);
	while ($tries++ < $max_tries) {
		($out, $rc) = $self->query({stdin => $keys_input, redact_stdin => 1}, 'unseal');
		return ($out, 0, '') if ($rc == 0) || ($out =~ /Vault is already unsealed/);

		# RISK: If the unseal fails, we log all available keys for recovery purposes
		# This is a security risk, as it exposes the unseal keys in logs, but is
		# necessary to prevent irrevocable sealing of the vault.
		trace(
			"[Attempt %s] Failed to unseal vault cluster at #M{%s} - all available keys (first three used):\n%s",
			$tries, $self->{url}, join("\n", map {sprintf("#C{%s}", $_)} @{$self->{unseal_keys}})
		);
		sleep(2); # brief pause before retrying
	}
	# If we reach here, all attempts failed
	return ('', $rc // 1, $out || "Failed to unseal vault cluster");
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
# vim: fdm=marker:foldlevel=1:noet
