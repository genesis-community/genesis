package Service::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term qw/csprintf/;

use Genesis::UI;
use JSON::PP qw/decode_json encode_json/;
use List::Util qw/min max/;
use POSIX ();
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
			# Tri-state: undef means no safe target ever stated it.  Coercing
			# to true here is what made safe's old default indistinguishable
			# from a deliberate choice -- see strongbox_intent below.
			strongbox => defined($strongbox) ? ($strongbox ? 1 : 0) : undef,
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
# strongbox_intent - what ~/.saferc states about a target, if anything {{{
sub strongbox_intent {
	my ($alias) = @_;
	return undef unless defined $alias;

	# safe locates its rc at $HOME/.saferc in every version that has ever
	# shipped, with no environment override, so this needs no discovery.
	my $rc = ($ENV{HOME} // '') . '/.saferc';
	return undef unless -f $rc;

	# The file belongs to safe.  An unreadable or unparseable one says
	# nothing about intent, and must not take down a command over a flag
	# that only affects seal-state reporting.
	my $config = eval {load_yaml_file($rc)};
	return undef unless ref($config) eq 'HASH';

	my $target = ($config->{vaults} // {})->{$alias};
	return undef unless ref($target) eq 'HASH';

	# Two keys, two eras.  v1.20.0+ writes `strongbox` and omits it when
	# off; v1.4.0 through v1.10.0 wrote `no_strongbox` and omitted it when
	# on.  Absence therefore means opposite things depending on who wrote
	# the file, which is why neither key present has to stay undef rather
	# than pick a side.  `strongbox` wins when both appear: safe's own
	# migration rewrites the legacy key into it, so it is the newer intent.
	return $target->{strongbox} ? 1 : 0 if exists $target->{strongbox};
	return $target->{no_strongbox} ? 0 : 1 if exists $target->{no_strongbox};
	return undef;
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
			# strongbox comes from the rc rather than from this listing:
			# safe reports the conclusion its own default produced, which
			# cannot distinguish an unstated flag from a disabled one.
			push @available_vaults, Service::Vault::Remote->new(
				$_->{url}, $_->{name}, $_->{verify}, $_->{namespace},
				strongbox_intent($_->{name}), $_->{mount}
			)
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
# target - resolve an alias or URL to a vault and connect_and_validate {{{
sub target {
	my ($class, $target, %opts) = @_;
	bail "Service::Vault->target requires an alias or url (use ".
		"Service::Vault::Remote->target for interactive selection)"
		unless defined $target && length $target;

	my ($url, @targets) = _get_targets($target);
	bail "Safe target \"#M{%s}\" not found.  Please create it".
		 "and authorize against it before re-attempting this command.",
		 $target
		if scalar(@targets) < 1;
	bail "Multiple safe targets use url #M{%s}:\n%s\n".
		 "\n".
		 "Your ~/.saferc file cannot have more than one target for the ".
		 "given url.  Please remove any duplicate targets before ".
		 "re-attempting this command.",
		 $url, join("", map {" - #C{$_}\n"} @targets)
		if scalar(@targets) > 1;

	# Deliberate: Service::Vault->find here, not $class->find.  The
	# resolved URL may point at a Local vault; a subclass override
	# like Service::Vault::Remote::find would silently drop it.
	# Matches the class-agnostic lookup pattern already used by
	# Service::Vault::Remote::attach.
	my $vault = (Service::Vault->find(url => $url))[0];
	return $vault->connect_and_validate();
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
# rebind - callback-context vault lookup by URL or legacy name {{{
sub rebind {
	my ($class) = @_;

	bail("Cannot rebind to vault in callback due to missing environment variables!")
		unless $ENV{GENESIS_TARGET_VAULT};

	my $vault;
	if (is_valid_uri($ENV{GENESIS_TARGET_VAULT})) {
		# URL form: class-agnostic lookup -- accepts whatever
		# vault kind sits at this URL in .saferc.
		$vault = ($class->find(url => $ENV{GENESIS_TARGET_VAULT}))[0];
		bail("Cannot rebind to vault at address '$ENV{GENESIS_TARGET_VAULT}` - not found in .saferc")
			unless $vault;
		trace "Rebinding to $ENV{GENESIS_TARGET_VAULT}: matches %s",
			$vault->{name} || "<unnamed>";
	} else {
		# Legacy named-target path: match against the default vault.
		my $default = $class->default;
		if ($default && $ENV{GENESIS_TARGET_VAULT} eq $default->{name}) {
			$vault = $default->ref_by_name();
			trace "Rebinding to default vault `$ENV{GENESIS_TARGET_VAULT}` (legacy mode)";
		}
	}
	return unless $vault;
	return $vault->set_as_current;
}

# }}}
# get_vault_from_descriptor - find unique vault from vault descriptor, or bail {{{
sub get_vault_from_descriptor {
	my ($class, $descriptor, $source) = @_;
	my $details = $class->parse_vault_descriptor($descriptor, $source);
	require Service::Vault::Remote;
	return Service::Vault::Remote->attach(
		url       => $details->{url},
		alias     => $details->{alias},
		tls       => $details->{tls},
		verify    => $details->{verify},
		namespace => $details->{namespace} // '',
		strongbox => $details->{strongbox},
	);
}

# }}}
# parse_vault_descriptor - Get all the components of the genesis.vault {{{
sub parse_vault_descriptor {
	my ($class, $vault_info, $source) = @_;
	$source ||= 'genesis.vault';
	# strongbox stays undef until a clause says otherwise: a descriptor that
	# omits it has stated nothing, and build_descriptor omits it for both
	# unstated and enabled.  Defaulting to 1 here turned every such env into
	# one that had asked for Strongbox.
	my ($url, $verify, $alias, $namespace, $strongbox, $tls, $domain, $port);
	# The alias may be the last thing in the descriptor, so the trailing
	# separator has to be optional -- requiring it left 'as' and the alias
	# behind as clauses and killed the parse.
	$vault_info =~ s/\s+as\s+(\S+)(?:\s|$)/ / and $alias = $1;
	for my $clause (split(' ',$vault_info)) {
		if ($clause =~ /^(no-)?strongbox$/) {
			$strongbox = $1 ? 0 : 1;
		} elsif ($clause =~ /^(no-)?verify/) {
			$verify = $1 ? 0 : 1;
		} elsif ($clause =~ /^(http(s)?:\/\/([^:\/]*)(?::([0-9]+))?)(?:\/(.*))?$/) {
			$url = $1;
			$tls = ($2 // '') eq 's' ? 1 : 0;
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

# public accessors: url, name, port, verify, namespace, strongbox, tls {{{
sub url {
	$_[0]->{url};
}

sub name {
	$_[0]->{name};
}

# undef for urls that rely on the scheme's default port -- callers that care
# about the port are local vaults, which always carry an explicit one.
sub port {
	$_[0]->{url} =~ m{^\w+://[^/:]+:(\d+)} ? $1 : undef;
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
	my $values;
	unless ($rc) {
		# safe exited cleanly, so let the payload decide rather than stderr:
		# a noverify target draws a TLS warning on every call, and treating
		# that as failure discards a perfectly good read.  stderr is still
		# the signal when safe fails without saying so in its exit code --
		# an unparseable payload keeps the error below.  Same reasoning as
		# read_json_from, which overrides $err for the JSON paths.
		trace(
			"safe wrote to stderr but exited 0; deferring to the payload: %s", $err
		) if $err;
		local $@;
		eval {$values = load_yaml($yaml)};
		$err = $@;
	}
	if ($rc || $err) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$err || '',$rc
		);
		return {};
	}
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

	return $self->_unpack_path_export($path, $data);
}
# }}}
# get_path_strict - get_path, except a failed read dies and a path with nothing stored comes back undef {{{
sub get_path_strict {
	my ($self, $path) = @_;
	$path =~ s{(^/*|/*$)}{}; # Trim preceeding and trailing / as safe doesn't honour it
	my ($out,$rc,$err) = $self->query({stderr => 0, redact_output => 1}, 'export', $path);
	my $data;
	unless ($rc) {
		local $@;
		eval {$data = load_json($out)};
		$err = $@; # safe exited cleanly, so only an unparseable payload is an error
	}
	if ($rc || $err) {
		# safe names a path with nothing stored on stderr, and exits the same
		# way for it as for an unreachable or sealed vault.  A token that can
		# list a path but not read it gets that same line after a refusal,
		# so a refusal anywhere in the output means the path was not read.  The
		# path quoted in the absent-secret line is left out of that scan, since
		# an environment name can hold 403 or forbidden and is not a refusal.
		my $reason = ($err // '') =~ s/\s+$//r;
		my $refusals = $reason =~ s/no secret exists at path\s+`[^`]*`//gr;
		my $refused = $refusals =~ /\b403\b|permission denied|forbidden/i;
		return undef if $rc && $reason =~ /no secret exists at path/ && !$refused;
		bail(
			"Could not read #C{%s} from vault at #M{%s}: %s\n\n".
			"Likely causes are that the token has no read access on that path, ".
			"that the vault is sealed, or that the vault cannot be reached.  ".
			"Run #C{safe export %s} with the same token to see which, and ".
			"#C{safe vault status} to check whether the vault is sealed.",
			$path, $self->{url}, length($reason) ? $reason : "safe exited with code $rc", $path
		);
	}
	return $self->_unpack_path_export($path, $data);
}
# }}}
# _unpack_path_export - nest the paths in a safe export under the path it was made for {{{
sub _unpack_path_export {
	my ($self, $path, $data) = @_;
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
	my ($self, $path, @args) = @_;
	$path =~ s/\/{2,}/\//g; # Clean up any double slashes from joins

	# A joined path:key names the key, so what follows is a value -- and
	# only one, since pairs after it would name a second key.
	if ($path =~ /:/) {
		my ($base, $key) = $path =~ m/^(.*?):([^:]*)$/;
		bail(
			"Could not write to #C{%s} in vault at #M{%s}: a joined path:key ".
			"names a single key, so it takes at most one value.",
			$path, $self->{url}
		) if @args > 1;
		($path, @args) = ($base, $key, @args);
	}

	bail(
		"Could not write to #C{%s} in vault at #M{%s}: no key was given.",
		$path, $self->{url}
	) unless @args;

	# A lone key, or an explicit undef value, means "prompt for it" -- the
	# undef case would otherwise read as a pair with an empty value.
	if (@args == 1 || (@args == 2 && !defined($args[1]))) {
		my $key = $args[0];
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

	bail(
		"Could not write to #C{%s} in vault at #M{%s}: set() takes key/value ".
		"pairs, but was given an odd number of arguments.",
		$path, $self->{url}
	) if @args % 2;

	my %pairs = @args;
	$self->_write_pairs($path, \%pairs);
	return @args == 2 ? $args[1] : \%pairs;
}

# }}}
# _write_pairs - write key/value pairs, in as few commands as safe allows {{{
sub _write_pairs {
	my ($self, $path, $pairs) = @_;

	my (@batch, %written);
	for my $key (sort CORE::keys %$pairs) {
		push(@batch, sprintf("%s=%s", $key, $pairs->{$key} // ''));
		next if length(join(' ', @batch)) <= 900;

		# The pair that crossed the line starts the next batch -- unless it
		# is alone, since there is no smaller write to fall back to.
		my @carry = (@batch > 1) ? (pop @batch) : ();
		$self->_write_batch($path, \@batch, \%written);
		@batch = @carry;
	}
	$self->_write_batch($path, \@batch, \%written) if @batch;
	return;
}

# }}}
# _write_batch - send one `safe set`, then confirm all of it is readable {{{
sub _write_batch {
	my ($self, $path, $batch, $written) = @_;
	return unless @$batch;

	my ($out,$rc) = $self->query('set', $path, @$batch);
	bail(
		"Could not write #C{%s} to vault at #M{%s}:\n%s",
		$path,$self->{url},$out
	) unless $rc == 0;

	# Confirm everything written so far, not just this batch: a batch that
	# merged into a stale base drops the earlier ones, not itself.
	for my $pair (@$batch) {
		my ($key, $value) = split /=/, $pair, 2;
		$written->{$key} = $value;
	}
	$self->_confirm_written($path, $written);
	return;
}

# }}}
# _confirm_timeout - how long a read-back may take before giving up {{{
sub _confirm_timeout {
	my $t = $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT};
	return $t if defined($t) && $t =~ /^\d+(?:\.\d+)?$/ && $t > 0;
	return 10;
}

# }}}
# _confirm_written - wait until a write reads back with the values sent {{{
sub _confirm_written {
	my ($self, $path, $written) = @_;
	return unless $self->needs_write_confirmation;

	# Values, not key names: a batch that merged into a stale base carries
	# the right names and the wrong contents.
	my $timeout = _confirm_timeout();
	my $deadline = gettimeofday() + $timeout;
	my @wrong;
	while (1) {
		my $have = $self->get($path);
		$have = {} unless ref($have) eq 'HASH';
		@wrong = grep {
			!defined($have->{$_})
			|| _readback_value($have->{$_}) ne _readback_value($written->{$_})
		} CORE::keys %$written;
		last unless @wrong;
		last if gettimeofday() >= $deadline;
		select(undef, undef, undef, 0.25);
	}
	bail(
		"Wrote #C{%s} to the vault at #M{%s}, but %s of its %s keys did not ".
		"read back within %ss.\n\n".
		"A write merges into whatever a read returns, so continuing would ".
		"discard what has already been written.\n\n".
		"This usually means the vault target is a standby node whose reads ".
		"lag the leader; pointing it at the cluster leader avoids it.",
		$path, $self->{url}, scalar(@wrong),
		scalar(CORE::keys %$written), $timeout
	) if @wrong;
	return;
}

# }}}
# _readback_value - flatten a read-back value for comparison with what was sent {{{
sub _readback_value {
	my ($value) = @_;
	# A path outside a kv mount (an approle role, for one) hands a
	# comma-separated list back as a list and a numeric string back as a
	# number, so we compare the flattened forms rather than the raw ones.
	return join(',', map {defined($_) ? "$_" : ''} @$value)
		if ref($value) eq 'ARRAY';
	return defined($value) ? "$value" : '';
}

# }}}
# _confirm_cleared - wait until a cleared path reads back empty {{{
sub _confirm_cleared {
	my ($self, $path) = @_;
	return unless $self->needs_write_confirmation;

	# The write after a clear merges into what a read returns, so keys that
	# outlive the delete are carried straight into the new value.
	my $timeout = _confirm_timeout();
	my $deadline = gettimeofday() + $timeout;
	my @left;
	while (1) {
		my $have = $self->get($path);
		@left = ref($have) eq 'HASH' ? CORE::keys %$have : ();
		last unless @left;
		last if gettimeofday() >= $deadline;
		select(undef, undef, undef, 0.25);
	}
	bail(
		"Cleared #C{%s} in the vault at #M{%s}, but %s of its keys were still ".
		"readable after %ss.\n\n".
		"The write that follows a clear merges into what a read returns, so ".
		"continuing would carry those keys into the new value.\n\n".
		"This usually means the vault target is a standby node whose reads ".
		"lag the leader; pointing it at the cluster leader avoids it.",
		$path, $self->{url}, scalar(@left), $timeout
	) if @left;
	return;
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
		# A stale read can call a path absent while its keys are still there
		# for the next write to merge into, so this is checked not trusted.
		$self->_confirm_cleared($path);
		return;
	} else {
		debug("Clearing #C{%s} in vault at #M{%s}", $path, $self->{url});
		($out,$rc,$err) = $self->query('rm', '-f', $path);
	}
	bail(
		"Could not clear #C{%s} in vault at #M{%s}:\n%s",
		$path,$self->{url},$out.$err
	) unless $rc == 0;
	$self->_confirm_cleared($path);
	return 1;
}

# }}}
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

	my %pairs;
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
					$pairs{"${key}[${i}]"} = $value->[$i] // '';
				}
			}
			next;  # Don't fall through to scalar handling
		}

		$pairs{$key} = $value // '';
	}

	return $data unless %pairs;
	# Straight to the writer: these keys are already the ones to store, so
	# set()'s path:key splitting would only mangle one containing a colon.
	$self->_write_pairs($path, \%pairs);
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
# max_json_string_value_length - return the per-string JSON value cap {{{
sub max_json_string_value_length {
	my ($self) = @_;

	return $self->{__max_json_string_value_length}
		if defined $self->{__max_json_string_value_length};

	if (defined($ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH})
		&& $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} =~ /^\d+$/
		&& $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} > 0)
	{
		return $self->{__max_json_string_value_length}
			= $ENV{GENESIS_VAULT_MAX_JSON_STRING_VALUE_LENGTH} + 0;
	}

	# Try to consult the server's listener config.  `safe curl
	# --data-only` strips safe's own wrapping; Vault's response envelope
	# (request_id, data, ...) is preserved, so the actual content lives
	# at $decoded->{data}->...
	my ($out, $rc, $err) = $self->query(
		{redact_output => 1, stderr => 0},
		'curl', '--data-only', '/sys/config/state/sanitized'
	);
	if ($rc == 0 && defined($out) && length($out)) {
		my $decoded = eval { decode_json($out) };
		if ($decoded && ref($decoded) eq 'HASH') {
			my $listeners = $decoded->{data}{listeners};
			if (ref($listeners) eq 'ARRAY' && @$listeners) {
				my $max = $listeners->[0]{config}{max_json_string_value_length};
				if (defined($max) && $max =~ /^\d+$/ && $max > 0) {
					return $self->{__max_json_string_value_length} = $max + 0;
				}
			}
		}
	}

	# Vault's compiled-in default for max_json_string_value_length.
	return $self->{__max_json_string_value_length} = 1024 * 1024;
}

# }}}
# needs_write_confirmation - whether a write must be read back to be trusted {{{
sub needs_write_confirmation {
	my ($self) = @_;

	return $self->{__needs_write_confirmation}
		if defined $self->{__needs_write_confirmation};

	if (defined($ENV{GENESIS_VAULT_CONFIRM_WRITES})
		&& $ENV{GENESIS_VAULT_CONFIRM_WRITES} =~ /^[01]$/)
	{
		return $self->{__needs_write_confirmation}
			= $ENV{GENESIS_VAULT_CONFIRM_WRITES} + 0;
	}

	# ha_enabled decides it, never is_self: leadership fails over, and the
	# target is usually a load balancer fronting more than one node.
	my ($out, $rc, $err) = $self->query(
		{redact_output => 1, stderr => 0},
		'curl', '--data-only', '/sys/leader'
	);
	if ($rc == 0 && defined($out) && length($out)) {
		my $decoded = eval {decode_json($out)};
		if (ref($decoded) eq 'HASH') {
			# sys endpoints answer flat, but the response envelope survives
			# on some builds, so accept the key in either position.
			my $ha = $decoded->{ha_enabled};
			$ha = $decoded->{data}{ha_enabled}
				if !defined($ha) && ref($decoded->{data}) eq 'HASH';
			return $self->{__needs_write_confirmation} = ($ha ? 1 : 0)
				if defined($ha);
		}
	}

	# A confirm that was not needed costs one read.  Skipping one that was
	# needed loses data with no error, so an unusable answer confirms.
	return $self->{__needs_write_confirmation} = 1;
}

# }}}
# kv_mount - the kv secrets engine a path is on, and which version of it {{{
sub kv_mount {
	my ($self, $path) = @_;
	$path = _kv_clean_path($path);

	my $known = $self->{__kv_mounts} //= {};
	for my $mount (sort {length($b) <=> length($a)} CORE::keys %$known) {
		return $known->{$mount} if index("$path/", $mount) == 0;
	}

	# The endpoint the vault CLI itself asks: any token with any access to
	# the path may read it, and Vault and OpenBao both answer it.
	my ($status, $reply, $reason) = $self->_kv_curl('GET', "sys/internal/ui/mounts/$path");
	my $data = ref($reply) eq 'HASH' && ref($reply->{data}) eq 'HASH' ? $reply->{data} : undef;
	if ($status >= 200 && $status < 300 && $data && defined($data->{path})) {
		my $type = $data->{type} // '';
		bail(
			"#C{%s} is on a #C{%s} secrets engine in the vault at #M{%s}, mounted at ".
			"#C{%s}, but only a kv secrets engine can hold it.\n\n".
			"This usually means the path was mistyped, or that a mount configured for ".
			"Genesis (an exodus or secrets mount) names the wrong engine.  Run ".
			"#C{safe vault secrets list} to see what is mounted where.",
			$path, $type || 'unknown', $self->{url}, $data->{path}
		) unless $type eq 'kv' || $type eq 'generic';
		my $options = ref($data->{options}) eq 'HASH' ? $data->{options} : {};
		my $mount = $data->{path} =~ s{^/+}{}r;
		$mount .= '/' unless $mount =~ m{/$};
		return $known->{$mount} = {
			path    => $mount,
			type    => $type,
			version => ($options->{version} // '1') eq '2' ? 2 : 1,
		};
	}

	# A vault from before kv v2 does not have the endpoint, and every kv
	# mount it has is a v1 one.
	return {path => undef, type => 'kv', version => 1} if $status == 404;

	bail(
		"Could not tell which kv mount #C{%s} is on in the vault at #M{%s}: %s\n\n".
		"Likely causes are that the vault is sealed or cannot be reached, or that ".
		"the token has no access at all to that path.  Run #C{safe curl GET ".
		"/sys/internal/ui/mounts/%s} with the same token to see the vault's answer, ".
		"and #C{safe vault status} to check whether the vault is sealed.",
		$path, $self->{url}, $reason, $path
	);
}

# }}}
# kv_read - read a whole secret, with the version a check-and-set write has to name {{{
sub kv_read {
	my ($self, $path) = @_;
	$path = _kv_clean_path($path);
	my $mount = $self->kv_mount($path);

	my ($status, $reply, $reason) = $self->_kv_curl('GET', _kv_data_uri($mount, $path));
	my $data = ref($reply) eq 'HASH' && ref($reply->{data}) eq 'HASH' ? $reply->{data} : undef;
	if ($mount->{version} == 2) {
		# A deleted or destroyed latest version still has a number, and still
		# answers 404, with that number in its metadata.  A secret that was
		# never written answers 404 with no metadata, and is version 0.
		my $meta = $data && ref($data->{metadata}) eq 'HASH' ? $data->{metadata} : undef;
		return {
			data       => ref($data->{data}) eq 'HASH' ? $data->{data} : undef,
			version    => $meta->{version} + 0,
			kv_version => 2,
		} if $status >= 200 && $status < 300 && $meta && defined($meta->{version});
		return {
			data       => undef,
			version    => $meta && defined($meta->{version}) ? $meta->{version} + 0 : 0,
			kv_version => 2,
		} if $status == 404;
	} else {
		return {data => $data // {}, version => undef, kv_version => 1} if $status >= 200 && $status < 300;
		return {data => undef, version => undef, kv_version => 1} if $status == 404;
	}

	bail(
		"Could not read #C{%s} from the vault at #M{%s}: %s\n\n".
		"Likely causes are that the vault is sealed or cannot be reached, or that ".
		"the token has no read access on that path.  Run #C{safe get %s} with the ".
		"same token to see which, and #C{safe vault status} to check whether the ".
		"vault is sealed.",
		$path, $self->{url}, $reason, $path
	);
}

# }}}
# kv_write - replace a whole secret, optionally only if it is still the version that was read {{{
sub kv_write {
	my ($self, $path, $data, %opts) = @_;
	$path = _kv_clean_path($path);
	my $mount = $self->kv_mount($path);
	my $v2 = $mount->{version} == 2;
	my $cas = $opts{cas};

	bug(
		"kv_write() was asked for a check-and-set write to #C{%s}, which is on a ".
		"kv v1 mount, and kv v1 has no check-and-set",
		$path
	) if defined($cas) && !$v2;
	bug("kv_write() was given a check-and-set version that is not a whole number: %s", $cas)
		if defined($cas) && $cas !~ /^\d+$/;

	my $payload = $v2
		? {data => $data, (defined($cas) ? (options => {cas => $cas + 0}) : ())}
		: $data;
	my ($status, $reply, $reason) = $self->_kv_curl('POST', _kv_data_uri($mount, $path), $payload);
	unless ($status >= 200 && $status < 300) {
		return 0 if defined($cas) && $status == 400
			&& $reason =~ /check-and-set parameter did not match/i;
		bail(
			"Could not write #C{%s} to the vault at #M{%s}: %s\n\n".
			"Likely causes are that the vault is sealed or cannot be reached, or that ".
			"the token has no create or update access on that path%s.  Run ".
			"#C{safe vault status} to check whether the vault is sealed, and check the ".
			"token's policies with #C{safe vault token lookup}.",
			$path, $self->{url}, $reason,
			$v2 ? sprintf(" (on a kv v2 mount the policy has to grant it on #C{%s})", _kv_data_uri($mount, $path)) : ''
		);
	}
	return 1 unless $v2;

	my $version = ref($reply) eq 'HASH' && ref($reply->{data}) eq 'HASH'
		? $reply->{data}{version} : undef;
	bail(
		"Wrote #C{%s} to the vault at #M{%s}, but the vault did not say which version ".
		"the write made, so it cannot be confirmed.\n\n".
		"A kv v2 mount always reports the version it wrote, so this usually means ".
		"something between Genesis and the vault (a proxy, or a different engine at ".
		"that mount) answered instead.  Check the secret with #C{safe get %s}.",
		$path, $self->{url}, $path
	) unless defined($version) && $version =~ /^\d+$/;

	$self->_confirm_kv_version($path, $version);
	return $version + 0;
}

# }}}
# kv_delete - delete a whole secret, or the latest version of one on kv v2 {{{
sub kv_delete {
	my ($self, $path) = @_;
	$path = _kv_clean_path($path);
	my $mount = $self->kv_mount($path);

	my ($status, undef, $reason) = $self->_kv_curl('DELETE', _kv_data_uri($mount, $path));
	return 1 if $status >= 200 && $status < 300;
	bail(
		"Could not delete #C{%s} from the vault at #M{%s}: %s\n\n".
		"Likely causes are that the vault is sealed or cannot be reached, or that ".
		"the token has no delete access on that path%s.  Run #C{safe vault status} ".
		"to check whether the vault is sealed, and check the token's policies with ".
		"#C{safe vault token lookup}.",
		$path, $self->{url}, $reason,
		$mount->{version} == 2 ? sprintf(" (on a kv v2 mount the policy has to grant it on #C{%s})", _kv_data_uri($mount, $path)) : ''
	);
}

# }}}
# _kv_curl - one kv API call through safe curl, with the status and reason it came back with {{{
sub _kv_curl {
	my ($self, $method, $uri, $payload) = @_;

	# safe curl takes a body only as an argument, which puts it on the
	# command line, so nothing secret goes through here.
	#
	# Without --data-only, every safe Genesis accepts prints the whole
	# response, status line first.  The status line is read rather than the
	# exit code, because safe before 1.20 exits 0 whatever the vault
	# answered, so a refusal there looks like success to anything else.
	my ($out, $rc, $err) = $self->query(
		{redact_output => 1, stderr => 0},
		'curl', $method, "/$uri",
		defined($payload) ? (encode_json($payload)) : ()
	);
	my ($status, $status_text, $body) = _kv_http_response($out);

	unless (defined($status)) {
		# Nothing came back from the vault, so the request never reached it
		# or never got an answer; safe says why on stderr.
		$err = ($err // '') =~ s/\e\[[0-9;]*m//gr;
		my $reason = $err =~ /\S/ ? ($err =~ s/^\s*!!\s*//r =~ s/\s+$//r =~ s/\s+/ /gr)
			: $rc ? "safe exited with code $rc and printed no response"
			: "safe printed no response";
		return (0, undef, $reason);
	}

	my $reply = $body =~ /\S/ ? eval {decode_json($body)} : undef;
	$reply = undef unless ref($reply) eq 'HASH';
	return ($status, $reply, '') if $status >= 200 && $status < 300;

	my @errors = $reply && ref($reply->{errors}) eq 'ARRAY'
		? grep {defined($_) && /\S/} @{$reply->{errors}} : ();
	my $reason = @errors
		? join('; ', map {s/\s+/ /gr =~ s/^ | $//gr} @errors)
		: "$method /$uri: $status $status_text" =~ s/\s+$//r;
	return ($status, $reply, $reason);
}

# }}}
# _kv_http_response - the status and body of a response as safe curl prints it {{{
sub _kv_http_response {
	my ($out) = @_;
	$out = ($out // '') =~ s/^\s+//r;
	my ($status, $text) = $out =~ m{\AHTTP/\d+(?:\.\d+)?[ \t]+(\d{3})(?:[ \t]+([^\r\n]*))?}
		or return;

	my ($head, $body) = split(/\r?\n\r?\n/, $out, 2);
	$body //= '';
	# Go prints a response that came chunked with its chunks, so they are
	# joined back into the body.
	if ($head =~ /^Transfer-Encoding:[ \t]*chunked[ \t]*\r?$/mi) {
		my $joined = '';
		while ($body =~ s/\A([0-9a-fA-F]+)[^\r\n]*\r?\n//) {
			my $size = hex($1);
			last unless $size;
			$joined .= substr($body, 0, $size, '');
			$body =~ s/\A\r?\n//;
		}
		$body = $joined;
	}
	return ($status + 0, $text // '', $body);
}

# }}}
# _kv_clean_path - a secret path as the kv API wants it {{{
sub _kv_clean_path {
	my ($path) = @_;
	bug("A kv secret path was not given") unless defined($path) && $path =~ /\S/;
	bug("A kv secret path names a whole secret, not a key: %s", $path) if $path =~ /:/;
	$path =~ s{/{2,}}{/}g;
	$path =~ s{^/+|/+$}{}g;
	return $path;
}

# }}}
# _kv_data_uri - where the kv API reads and writes a secret's data {{{
sub _kv_data_uri {
	my ($mount, $path) = @_;
	return $path unless $mount->{version} == 2;
	return $mount->{path}.'data/'.substr($path, length($mount->{path}));
}

# }}}
# _confirm_kv_version - wait until reads return a version at least as new as the one written {{{
sub _confirm_kv_version {
	my ($self, $path, $version) = @_;
	return unless $self->needs_write_confirmation;

	my $timeout = _confirm_timeout();
	my $deadline = gettimeofday() + $timeout;
	my $seen;
	while (1) {
		$seen = $self->kv_read($path)->{version} // 0;
		return if $seen >= $version;
		last if gettimeofday() >= $deadline;
		select(undef, undef, undef, 0.25);
	}
	bail(
		"Wrote version %s of #C{%s} to the vault at #M{%s}, but reads still ".
		"returned version %s after %ss.\n\n".
		"Whatever reads next would act on the older version.  This usually means ".
		"the vault target is a standby node whose reads lag the leader; pointing it ".
		"at the cluster leader avoids it.",
		$version, $path, $self->{url}, $seen, $timeout
	);
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
	# Only a stated setting earns a clause, in either direction.  A target
	# that never stated the flag emits nothing, so the descriptor carries
	# all three states and parse_vault_descriptor reads back what was meant.
	$descriptor .= $self->strongbox ? " strongbox" : " no-strongbox"
		if defined($self->strongbox);
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
	# key1..keyN in numeric order, then anything else by name, so every run
	# offers the keys in the same order.
	my $stored = $self->get($keys_path) // {};
	my @names = sort {
		my ($x) = $a =~ /^key([0-9]+)$/;
		my ($y) = $b =~ /^key([0-9]+)$/;
		(defined($x) ? 0 : 1) <=> (defined($y) ? 0 : 1)
			|| ($x // 0) <=> ($y // 0)
			|| $a cmp $b
	} CORE::keys(%$stored);
	$self->{unseal_keys} = [map {$stored->{$_}} @names];
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

	# Use the stdin option with query to pass keys to safe unseal.  safe's
	# stderr is kept, because it is where safe reports that Strongbox was off
	# and only the targeted address was reached.  Its output and stderr stay
	# out of the trace, in case safe ever echoes a key.
	my ($out, $rc, $err);
	my ($tries, $max_tries) = (0, 3);
	while ($tries++ < $max_tries) {
		($out, $rc, $err) = $self->query({stdin => $keys_input, redact_output => 1, redact_stderr => 1}, 'unseal');
		if (($rc == 0) || ($out =~ /Vault is already unsealed/)) {
			# A success here may only cover one node.  The caller checks
			# status next, which also sees only that node, so nothing
			# downstream can tell an unsealed cluster from an unsealed
			# member of a sealed one.
			my @caveat = $self->_strongbox_unseal_caveat;
			warning(@caveat) if @caveat;
			return ($self->_redact_unseal_keys($out), 0, '');
		}

		# Seal material never goes to a trace or a log.  Anyone who has to
		# finish by hand still has the keys at <secrets_mount>vault/seal/keys.
		trace(
			"[Attempt %s] Failed to unseal vault cluster at #M{%s}",
			$tries, $self->{url}
		);
		$self->_pause(2) if $tries < $max_tries; # nothing to wait for before giving up
	}

	# If we reach here, all attempts failed.  safe's own words go back to the
	# caller, who prints them, so any key it echoed is struck out first.
	my @reason = ($self->_redact_unseal_keys($out) || "Failed to unseal vault cluster");
	unshift(@reason, $self->_redact_unseal_keys($err)) if $err;
	my @caveat = $self->_strongbox_unseal_caveat;
	push(@reason, csprintf(@caveat)) if @caveat;
	return ('', $rc // 1, join("\n\n", @reason));
}

# }}}
# unseal_nodes - unseal each listed node through its own sys/unseal {{{
#
# A Raft cluster's safe target reaches only one node, which cannot elect a
# leader on its own, and with standby reads disabled nothing authenticated
# works until a quorum is open.  Each node is given the fetched keys a
# threshold's worth at a time.  A well-formed but wrong key, such as one left
# over from a rekey, is only found out once the threshold is reached, when
# the node throws the whole round away, so the next combination of keys is
# tried after a failed one.  Keys go to curl on stdin and never appear in an
# argument, a trace, or a result.
#
# An optional leading hashref carries a deadline, past which no request
# starts and against which every request is capped, and a record of the
# rounds that already failed on each node, so a later pass never repeats
# them.  Returns one {address, unsealed, message} hashref per node.
sub unseal_nodes {
	my $self = shift;
	my $opts = CORE::ref($_[0]) eq 'HASH' ? shift : {};
	my @nodes = @_;
	my @keys = @{$self->{unseal_keys} // []};
	my $failed = $opts->{failed_rounds} // {};

	# One request to a node, capped at the time left before the deadline.
	# Under a tenth of a second counts as no time at all, because curl reads
	# a limit that rounds to zero as no limit.
	my $ask = sub {
		my ($node, $method, $path, $payload) = @_;
		my $time = 10;
		if (defined($opts->{deadline})) {
			$time = min($time, $opts->{deadline} - $self->_now);
			return (undef, 'not reached before the time allowed ran out') if $time < 0.1;
		}
		return $self->_node_request($node, $method, $path, $payload, $time);
	};

	my @results;
	for my $node (@nodes) {
		my $result = {address => $node, unsealed => 0};
		push @results, $result;

		my ($state, $problem) = $ask->($node, 'GET', 'sys/seal-status');
		unless ($state && exists($state->{sealed})) {
			$result->{message} = $problem // 'unreachable';
			next;
		}
		unless ($state->{sealed}) {
			@$result{qw/unsealed message/} = (1, 'already unsealed');
			next;
		}
		unless (@keys) {
			$result->{message} = 'sealed, and no unseal keys were fetched';
			next;
		}
		my $threshold = ($state->{t} // '') =~ /^[1-9][0-9]*$/ ? $state->{t} : 3;
		if ($threshold > @keys) {
			$result->{message} = sprintf(
				'sealed, and it needs %d unseal keys where only %d were fetched',
				$threshold, scalar(@keys)
			);
			next;
		}

		my $progress = $state->{progress};
		my ($opened, $failure, $cut_short);
		for my $round (_combinations($threshold, 0 .. $#keys)) {
			my $id = join(',', @$round);
			next if $failed->{$node}{$id};

			# Progress this round did not make belongs to someone else, such as
			# an operator unsealing by hand, or to an earlier round of ours that
			# a malformed key cut short.  Mixing it into this round would spoil
			# the round, so it is cleared, but only now that a round is about to
			# be submitted.
			if (!defined($progress) || $progress > 0) {
				my ($reset, $why) = $ask->($node, 'PUT', 'sys/unseal', {reset => JSON::PP::true});
				unless ($reset && exists($reset->{sealed}) && !($reset->{progress} // 0)) {
					$failure = $why // 'would not reset its unseal progress, so no keys were sent to it';
					last;
				}
				$progress = 0;
			}

			my ($reply, $why);
			my $sent = 0;
			for my $index (@$round) {
				($reply, $why) = $ask->($node, 'PUT', 'sys/unseal', {key => $keys[$index]});
				$sent++;
				last unless $reply && exists($reply->{sealed}) && $reply->{sealed};
			}
			unless ($reply) {
				$failure = $why // 'stopped answering while it was being unsealed';
				last;
			}
			if (exists($reply->{sealed}) && !$reply->{sealed}) {
				$opened = 1;
				last;
			}

			# Only a round the node judged in full is known to be wrong.  One cut
			# short by an error, such as a new Raft node that is not ready yet,
			# says nothing about its keys, so a later pass may send it again.
			if ($sent == @$round) {
				$failed->{$node}{$id} = 1;
			} else {
				$cut_short++;
			}
			$progress = $reply->{progress};
		}
		unless ($opened || $failure) {
			($state, $problem) = $ask->($node, 'GET', 'sys/seal-status');
			$opened = $state && exists($state->{sealed}) && !$state->{sealed};
			$failure = $problem unless $state;
		}
		@$result{qw/unsealed message/} = $opened
			? (1, 'unsealed')
			: (0, $failure // ($cut_short
				? 'still sealed, and it refused keys before a round was complete, so it will be tried again'
				: 'still sealed after every combination of unseal keys was tried'));
	}
	return @results;
}

# }}}
# unseal_cluster - unseal a Raft cluster and wait for it to elect a leader {{{
#
# Everything here happens within $timeout seconds of wall-clock time.  No
# request starts after the deadline, and each one is capped at the time left.
# Nodes that are still starting when first asked are asked again every few
# seconds until a quorum is open, and a round of keys that failed on a node
# is never sent to it again.  With a quorum, this waits for an active node
# and then, if time remains, gives any node that is still closed one more
# try.  Without a quorum no leader can be elected, so it does not wait for
# one.  Returns a hashref with the per-node results, the active node's
# address (undef when none emerged), the number of open nodes, and the
# quorum size.
sub unseal_cluster {
	my ($self, $timeout, @nodes) = @_;
	my $pass = {deadline => $self->_now + $timeout, failed_rounds => {}};
	my $quorum = int(scalar(@nodes) / 2) + 1;
	my $left = sub {$pass->{deadline} - $self->_now};

	# A bound of zero still makes one full pass, with each request allowed its
	# usual time, so that setting it to zero means "do not wait" rather than
	# "do nothing".
	my %result = map {$_->{address} => $_}
		$self->unseal_nodes($timeout > 0 ? $pass : {failed_rounds => $pass->{failed_rounds}}, @nodes);
	my $open = sub {scalar(grep {$result{$_}{unsealed}} @nodes)};
	my $closed = sub {grep {!$result{$_}{unsealed}} @nodes};

	while ($open->() < $quorum && $left->() > 0) {
		my $wait = max(0, min(3, $left->()));
		$self->_pause($wait) if $wait > 0;
		last if $left->() <= 0;
		$result{$_->{address}} = $_ for $self->unseal_nodes($pass, $closed->());
	}

	my $active;
	if ($open->() >= $quorum) {
		$active = $self->wait_for_active_node(max(0, $left->()), @nodes);
		my @late = $closed->();
		$result{$_->{address}} = $_ for (@late && $left->() > 0 ? $self->unseal_nodes($pass, @late) : ());
	}

	return {
		nodes  => [map {$result{$_}} @nodes],
		active => $active,
		open   => $open->(),
		quorum => $quorum,
	};
}

# }}}
# wait_for_active_node - wait, within a bound, for a cluster to elect a leader {{{
#
# Unsealing a quorum is not the end of it, because a Raft cluster then has to
# elect an active node before an authenticated request can succeed.  Asks
# each node's unauthenticated sys/health every few seconds until $timeout
# seconds of wall-clock time have passed.  Each request is capped at the time
# that remains, so a node that never answers cannot stretch the wait.  Every
# node is asked at least once, even when $timeout is zero.  Returns the active
# node's address, or undef when none emerged.
sub wait_for_active_node {
	my ($self, $timeout, @nodes) = @_;
	my $deadline = $self->_now + $timeout;
	my $interval = 3;
	my $first_round = 1;
	while (1) {
		for my $node (@nodes) {
			my $left = $deadline - $self->_now;
			return undef if $left <= 0 && !$first_round;
			my $health = $self->_node_request(
				$node, 'GET', 'sys/health', undef, max(1, min(10, $left))
			);
			return $node
				if $health && exists($health->{standby})
				&& !$health->{sealed} && !$health->{standby};
		}
		$first_round = 0;
		my $left = $deadline - $self->_now;
		last if $left <= 0;
		$self->_pause(min($interval, $left));
	}
	return undef;
}

# }}}
# _strongbox_unseal_caveat - why an unseal may have covered only one node {{{
sub _strongbox_unseal_caveat {
	my ($self) = @_;

	# Nothing to say when Strongbox is on: safe walked the cluster.
	return () if $self->strongbox;

	return (
		"Strongbox is not enabled for safe target #C{%s}, so #C{safe unseal} ".
		"only reached #M{%s}; any other nodes in the cluster were left as they ".
		"were.%s\n".
		"Enable it with #G{safe target %s--strongbox %s %s}.",
		$self->name, $self->url,
		defined($self->strongbox) ? ''
			: "  The target does not state the flag at all, which is how every ".
			  "target written before safe made Strongbox opt-in appears.",
		$self->verify ? '' : '-k ', $self->url, $self->name
	);
}

# }}}
# _node_request - one unseal-related API call to a single node {{{
#
# $node is an address with an optional port, as in 10.0.0.5:8200 or
# [fd00::5]:8200, and a missing port means the target's.  The request goes to
# the target's own URL, and --connect-to sends the connection to the node, so
# TLS is verified against the name safe verifies, and -k is passed only when
# the target skips verification.  The rule leaves its first host empty, which
# matches whatever curl makes of the URL's host, so a target written in a
# non-canonical form still reaches the node rather than itself.  -q comes
# first so that no curlrc can add a trace or a key log, and CURL_HOME and
# SSLKEYLOGFILE are cleared for the same reason.  A $payload goes to curl as
# a JSON body on stdin, and the reply is kept out of the trace.  $max_time
# caps the whole request in seconds.  Returns the decoded reply, or undef
# when the node did not answer with JSON; in list context, a second value
# says why not, naming the node when its certificate fails verification.
sub _node_request {
	my ($self, $node, $method, $path, $payload, $max_time) = @_;
	my $give = sub {wantarray ? @_ : $_[0]};

	my ($scheme, $host, $port) = _split_url($self->url);
	return $give->(undef, 'the target is not an http or https URL') unless $scheme;
	my ($address, $node_port) = $node =~ /^\[([^\]]+)\](?::([0-9]+))?$/
		? ($1, $2)
		: $node =~ /^([^:]+)(?::([0-9]+))?$/ ? ($1, $2) : ($node, undef);
	$node_port ||= $port;
	my $bracket = sub {$_[0] =~ /:/ ? "[$_[0]]" : $_[0]};

	# curl takes a limit that rounds to zero as no limit at all, so every
	# limit is rounded up to the next tenth of a second, and never below one.
	$max_time = 10 unless defined($max_time) && $max_time > 0;
	my $tenths = sub {sprintf('%.1f', max(1, POSIX::ceil($_[0] * 10 - 1e-9)) / 10)};
	my @args = (
		'-q', '-s',
		'--connect-timeout', $tenths->(min(5, $max_time)),
		'-m', $tenths->($max_time),
		'-X', $method,
		'--connect-to', join(':', '', $port, $bracket->($address), $node_port),
	);
	push @args, '-k' unless $self->verify;

	my $opts = {
		stderr => 0,
		redact_output => 1,
		env => {CURL_HOME => undef, SSLKEYLOGFILE => undef},
	};
	if (defined($payload)) {
		$opts->{stdin} = encode_json($payload);
		push @args, '-H', 'Content-Type: application/json', '--data-binary', '@-';
	}

	my ($out, $rc) = run($opts, 'curl', @args, sprintf(
		'%s://%s:%s/v1/%s', $scheme, $bracket->($host), $port, $path
	));
	if ($rc) {
		# Verification stays on, and fails closed.  Exit 35 is any failed
		# handshake, which includes a node still starting that resets the
		# connection, so it is worded more loosely than the exits that can
		# only mean the certificate did not check out.
		return $give->(undef, sprintf(
			'the TLS handshake with %s failed, which can mean its certificate does '.
			'not match the target name %s or that the node is still starting (curl exit 35)',
			$node, $host
		)) if $rc == 35;
		return $give->(undef, sprintf(
			'TLS verification failed: the certificate that %s presented does not '.
			'verify against the target name %s (curl exit %d)',
			$node, $host, $rc
		)) if grep {$rc == $_} (51, 58, 60);
		return $give->(undef, $rc == 28
			? 'unreachable (timed out)'
			: sprintf('unreachable (curl exit %d)', $rc));
	}
	return $give->(undef, 'unreachable (no answer)') unless $out;
	my $reply = eval {decode_json($out)};
	return $give->(undef, 'answered, but not with JSON') unless CORE::ref($reply) eq 'HASH';
	return $give->($reply, undef);
}

# }}}
# _redact_unseal_keys - strike any fetched unseal key out of a message {{{
sub _redact_unseal_keys {
	my ($self, $text) = @_;
	return $text unless defined($text);
	for my $key (grep {defined($_) && length($_)} @{$self->{unseal_keys} // []}) {
		$text =~ s/\Q$key\E/<redacted>/g;
	}
	return $text;
}

# }}}
# _now - the current time in seconds; a seam for tests {{{
sub _now {
	return scalar(gettimeofday());
}

# }}}
# _pause - sleep between attempts; a seam for tests {{{
sub _pause {
	Time::HiRes::sleep($_[1]);
}

# }}}

### Private helper functions {{{

# _split_url - scheme, bare host, and port of a vault URL {{{
# The port defaults by scheme, and an IPv6 host loses its brackets.  Returns
# the empty list for anything that is not an http or https URL.
sub _split_url {
	my ($url) = @_;
	return () unless ($url // '') =~ m{^(https?)://(?:\[([^\]]+)\]|([^:/\[\]]+))(?::([0-9]+))?(?:/|$)};
	return ($1, $2 // $3, $4 || ($1 eq 'https' ? 443 : 80));
}

# }}}
# _combinations - every way to choose $size items from a list, in order {{{
# Lexicographic by position, so the first combination is the first $size
# items.  Stops at 64 combinations, which covers every choice of 3 from 8.
sub _combinations {
	my ($size, @items) = @_;
	my @found;
	my $walk;
	$walk = sub {
		my ($from, @picked) = @_;
		return if @found >= 64;
		return push(@found, [@picked]) if @picked == $size;
		for my $i ($from .. $#items) {
			last if @items - $i < $size - @picked;
			$walk->($i + 1, @picked, $items[$i]);
		}
	};
	$walk->(0);
	undef $walk;
	return @found;
}

# }}}
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
# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
