package Genesis::Env::Secrets::Store::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::Term;

use vars qw($AUTOLOAD);
sub AUTOLOAD {
	my $self = shift;

	# Never propagate DESTROY methods
	return if $AUTOLOAD =~ /::DESTROY$/;

	# Strip off its leading package name (such as Employee::)
	$AUTOLOAD =~ s/^.*:://;
	$self->{service}->$AUTOLOAD(@_);
}

### Class Methods {{{

# new - crate a new Vault-based environment secrets store {{{
sub new {
	my ($class, $env, %opts) = @_;

	# validate call
	my @required_options = qw/service/;
	my @valid_options = (@required_options, qw/mount_override slug_override root_ca_override/);
	bug("No '$_' specified in call to Genesis::Env::SecretsStore::Vault->new")
		for grep {!$opts{$_}} @required_options;
	bug("Unknown '$_' option specified in call to Genesis::Env::SecretsStore::Vault->new")
		for grep {my $k = $_; ! grep {$_ eq $k} @valid_options} keys(%opts);

	$opts{mount_override}   //= $env->lookup('genesis.secrets_mount');
	$opts{slug_override}    //= $env->lookup(['genesis.secrets_path','params.vault_prefix','params.vault']);
	$opts{root_ca_override} //= $env->lookup('genesis.root_ca_path','') =~ s/\/$//r;

	return bless({
			env => $env,
			%opts
		},$class
	);
}

# }}}
# }}}

### Instance Methods {{{

sub env {$_[0]->{env}}
sub service {$_[0]->{service}}

sub default_mount {
	'/secret/'
}
sub mount {
	my $self = shift;
	unless (defined($self->{__mount})) {
		$self->{__mount} = ($self->{mount_override} || $self->default_mount);
		$self->{__mount} =~ s|^/?(.*?)/?$|/$1/|;
	}
	return $self->{__mount};
}

sub default_slug {
	my $self = shift;
	(my $slug = $self->env->name) =~ s|-|/|g;
	$slug .= "/".$self->env->type;
	return $slug
}

sub slug {
	my $self = shift;
	unless (defined($self->{__slug})) {
		$self->{__slug} = $self->{slug_override} || $self->default_slug;
		$self->{__slug} =~ s|^/?(.*?)/?$|$1|;
	}
	return $self->{__slug};
}

sub base {
	my $self = shift;
	$self->mount . $self->slug . '/';
}

sub path {
	($_[0]->base().($_[1]||'')) =~ s/\/$//r;
}

# root_ca_path - returns the root_ca_path, if provided by the environment file (env: GENESIS_ROOT_CA_PATH) {{{
sub root_ca_path {
	my $self = shift;
	unless (exists($self->{__root_ca_path})) {
		$self->{__root_ca_path} = $self->{root_ca_override} || $ENV{GENESIS_ROOT_CA_PATH} || '';
		$self->{__root_ca_path} =~ s|^/?(.*?)/?$|/$1| if $self->{__root_ca_path};
	}

	return $self->{__root_ca_path};
}

sub store_data {
	my $self = shift;
	$self->{__data} //= read_json_from($self->service->query('export', grep {$_} ($self->base, $self->root_ca_path)));
	return $self->{__data}
}

sub store_paths {
	return keys %{$_[0]->store_data};
}

# }}}

sub read   {
	my ($self, $secret) = @_;
	my $path = $secret->path;
	$path .= ":".$secret->default_key if $secret->default_key;
	$secret->set_value($self->service->get($self->path($path)));
	if ($secret->can('format_path') && (my $format_path = $secret->format_path)) {
		my $format_path = $secret->format_path;
		secret->set_format_value($self->service->get($self->path($format_path)));
	}
	$secret->promote_value_to_stored();
	return $secret;
}

sub write   {
	my ($self, $secret) = @_;
	my @results = ();
	if ($secret->path =~ ':') {
		$self->service->set(split(":",$self->path($secret->path),2), $secret->value);
		if ($secret->can('format_path') && (my $format_path = $secret->format_path)) {
			$self->service->set($self->path($format_path), $_, $secret->calc_format_value);
		}
	} elsif (ref($secret->value) eq 'HASH') {
		my %values = %{$secret->value};
		for my $key ( map {(split ':', $_, 2 )[1]} $self->service->keys($self->path($secret->path))) {
			next if exists($secret->value->{$key});
			$self->service->query('rm', join(":", ($self->path($secret->path),$_)));
		}	;
		$self->service->set($self->path($secret->path), $_, $values{$_}) for keys %values;
	} else {
		my $key = $secret->default_key//'value';
		$self->service->set($self->path($secret->path), $key, $secret->value);
	}
	$secret->promote_value_to_stored();

	delete($self->{__data});
	return $secret;
}

sub fill  {
	my ($self, @secrets) = @_;
	my $data = $self->store_data();
	my $pause = 0;
	for my $secret (@secrets) {
		my $path = $self->path($secret->path) =~ s#/?(.*?)/?#$1#r;
		my $key = $secret->default_key;
		($path,$key) = split(":",$path,2) if $path =~ /:/;
		next unless defined($data->{$path});
		if (defined($key)) {
			$secret->set_value($data->{$path}{$key});
			if ($secret->can('format_path') && (my $format_path = $secret->format_path)) {
				my ($_path, $_key) = split(":", $self->path($format_path) =~ s/^\///r, 2);
				$secret->set_format_value($data->{$_path}{$_key})
			}
			$secret->promote_value_to_stored;
		} else {
			$secret->set_value($data->{$path}, in_sync => 1)
		}
	}
	return;
}
sub check {
	my ($self, $secret) = @_;
	my $ok = $self->get($secret) unless $secret->has_value;
	return $ok;
}

sub validate {
	my ($self, $secret) = @_;
	my $ok = $self->get($secret) unless $secret->has_value;
	return $secret->validate();
}

sub generate {
	my ($self, $secret) = @_;

}

sub regenerate {}

sub remove {}

sub remove_all {}

# process_kit_secret_plans - perform actions on the kit secrets: add,recreate,renew,check,remove {{{
sub _process_kit_secret_plans {
	my ($self, $action, $env, $update, %opts) = @_;
	$opts{invalid} ||= 0;

	bug("#R{[Error]} Unknown action '$action' for processing kit secrets")
		if ($action !~ /^(add|recreate|renew|remove)$/);

	$update->('wait', msg => "Parsing kit secrets descriptions");
	my @plans = $self->kit_secrets_parser->parse(
		root_ca_path => $self->root_ca_path,
		paths => $opts{paths}
	)->plans();

	my @errors = map {my ($p,$t,$m) = describe_kit_secret_plan(%$_); sprintf "%s: %s", $p, $m} grep {$_->{type} eq 'error'} @plans;
	$update->('wait-done', result => (@errors ? 'error' : 'ok'), msg => join("\n", @errors));
	return if (@errors);

	if ($opts{invalid}) {
		@plans = $self->_get_failed_secret_plans($action, $env, $update, $opts{invalid} == 2, @plans);
		return $update->('empty', msg => sprintf(
				"No %s secrets found%s.",
				($opts{invalid} == 2) ? "invalid" : "problematic",
				@{$opts{paths}} ? " under the specified paths/filters" : ""
			)
		) unless scalar(@plans);
	}
	#Filter out any path that has no plan - only x509 has support for renew
	#TODO: make this generalized if other things are supported in the future
	@plans = grep {$_->{type} eq 'x509'} @plans if $action eq 'renew';
	return $update->('empty') unless scalar(@plans);

	if ($action =~ /^(remove|recreate|renew)$/ && !$opts{no_prompt} && !$opts{interactive}) {
		(my $actioned = $action) =~ s/e?$/ed/;
		my $permission = $update->('prompt',
			class => 'warning',
			msg => sprintf(
				"The following secrets will be ${actioned} under path '#C{%s}':\n  %s",
				$env->secrets_base,
				join("\n  ",
					map {bullet $_, inline => 1}
					map {_get_plan_paths($_)}
					@plans
				)
			),
			prompt => "Type 'yes' to $action these secrets");
		return $update->('abort', msg => "\nAborted!\n")
			if $permission ne 'yes';
	}

	my ($result, $err, $idx);
	$update->('init', total => scalar(@plans));
	for (@plans) {
		my ($path, $label, $details) = describe_kit_secret_plan(%$_);
		$update->('start-item', path => $path, label => $label, details => $details);
		if ($opts{interactive}) {
			my $confirm = $update->('inline-prompt',
				prompt => sprintf("%s [y/n/q]?", $action),
			);
			if ($confirm ne 'y') {
				$update->('done-item', result => 'skipped');
				return $update->('abort', msg => "#Y{Quit!}\n") if ($confirm eq 'q');
				next;
			}
		}
		my $now_t = Time::Piece->new(); # To prevent clock jitter
		my @command = _generate_secret_command($action, $env->secrets_base, %$_);
		if ($_->{type} eq "provided") {
			if ($action eq 'add' || ($action eq 'recreate' && $_->{fixed})) {
				my $path = $env->secrets_base.$_->{path};
				my (undef, $missing) = $self->query('exists',$path);
				if (!$missing) {
					$update->('done-item', result => 'skipped');
					next;
				}
			}
			if (!@command) {
				$update->('done-item', result => 'error', msg => "Cannot prompt for user input from a non-controlling terminal");
				last;
			}

			my $interactive = 1;
			$update->("notify", msg => "#Yi{user input required:\n}");
			if (CORE::ref($command[0]) eq 'CODE') {
				my $precommand = shift @command;
				my @precommand_args;
				while (my $arg = shift @command) {
					last if $arg eq '--';
					push @precommand_args, $arg;
				}
				$interactive = $precommand->(@precommand_args);
			}
			if (@command) {
				$update->('notify', msg=> "\nsaving user input ... ", nonl => 1) if ! $interactive;
				my ($out,$rc) = $self->query({interactive => $interactive}, @command);
				$update->('notify', msg=> "\nsaving user input ... ", nonl => 1) if $interactive;
				$update->('done-item', result => ($rc ? 'error': 'ok'));
				last if $rc;
			}
		} else {
			my ($out, $rc) = $self->query(@command);
			$out = join("\n", grep {
					my (undef, $key) = split(':',$path);
					$_ !~ /^$key: [a-f0-9]{8}(-[a-f0-9]{4}){4}[a-f0-9]{8}$/;
				} split("\n", $out )) if ( $_->{type} eq 'uuid');
			if ($out =~ /refusing to .* as it is already present/ ||
			    $out =~ /refusing to .* as the following keys would be clobbered:/) {
				$update->('done-item', result => 'skipped')
			} elsif ( $action eq 'renew' && $out =~ /Renewed x509 cert.*expiry set to (.*)$/) {
				my $expires = $1;
				eval {
					(my $exp_gmt = $1) =~ s/UTC/GMT/;
					my $expires_t = Time::Piece->strptime($exp_gmt, "%b %d %Y %H:%M %Z");
					my $days = sprintf("%.0f",($expires_t - $now_t)->days());
					$update->('done-item', result => 'ok', msg => checkbox(1)."Expiry updated to $expires ($days days)");
				};
				$update->('done-item', result => 'ok', msg => "Expiry updated to $expires") if $@;
			} elsif ($_->{type} eq 'dhparams' && $out && !$rc) {
				if ($out =~ /Generating DH parameters.*This is going to take a long time.*\+\+\*\+\+\*\s*$/s) {
					$update->('done-item', result => 'ok')
				} else {
					$update->('done-item', result => 'error', msg => $out);
				}
			} elsif (!$out) {
				$update->('done-item', result => 'ok')
			} else {
				$update->('done-item', result => 'error', msg => $out);
			}
			last if ($rc);
		}
	}
	return $update->('completed');
}

# }}}
# validate_kit_secrets - validate kit secrets {{{
sub validate_kit_secrets {
	my ($self, $action, $env, $update, %opts) = @_;
	$opts{validate} ||= 0;
	bug("#R{[Error]} Unknown action '$action' for checking kit secrets")
		if ($action !~ /^(check|validate)$/);

	$update->('wait', msg => "Parsing kit secrets descriptions");
	my @plans = parse_kit_secret_plans(
		$env->dereferenced_kit_metadata,
		[$env->features],
		root_ca_path => $env->root_ca_path,
		paths => $opts{paths});

	my @errors = map {my ($p,$t,$m) = describe_kit_secret_plan(%$_); sprintf "%s: %s", $p, $m} grep {$_->{type} eq 'error'} @plans;
	$update->('wait-done', result => (@errors ? 'error' : 'ok'), msg => join("\n", @errors));
	return if (@errors);

	$update->('wait', msg => "Retrieving all existing secrets");
	my ($secret_contents,$err) =$self->all_secrets_for($env);
	$update->('wait-done', result => ($err ? 'error' : 'ok'), msg => $err);
	return if $err;

	$update->('init', total => scalar(@plans));
	for my $plan (@plans) {
		my ($path, $label, $details) = describe_kit_secret_plan(%$plan);
		$update->('start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = _validate_kit_secret($action,$plan,$secret_contents,$env->secrets_base,\@plans);
		$update->('done-item', result => $result, msg => $msg, action => ($plan->{type} eq 'provided' ? 'check' : $action));
	}
	return $update->('completed');
}

# }}}
# _get_failed_secret_plans - list the plans for failed secrets {{{
sub _get_failed_secret_plans {
	my ($self, $scope, $env, $update, $include_warnings, @plans) = @_;
	$update->('wait', msg => "Retrieving all existing secrets");
	my ($secret_contents,$err) =$self->all_secrets_for($env);
	$update->('wait-done', result => ($err ? 'error' : 'ok'), msg => $err);
	return () if $err;

	my @failed;
	my ($total, $idx) = (scalar(@plans), 0);
	$update->('init', action => "Checking for failed".($scope eq 'recreate' ? ' or missing' : '')." secrets", total => scalar(@plans));
	for my $plan (@plans) {
		my ($path, $label, $details) = describe_kit_secret_plan(%$plan);
		$update->('start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = _validate_kit_secret('validate',$plan,$secret_contents,$env->secrets_base, \@plans);
		if ($result eq 'error' || ($result eq 'warn' && $include_warnings) || ($result eq 'missing' && $scope eq 'recreate')) {
			$update->('done-item', result => $result, action => 'validate', msg => $msg) ;
			push @failed, $plan;
		} else {
			$update->('done-item', result => 'ok', action => 'validate')
		}
	}
	$update->('notify', msg => sprintf("Found %s invalid%s secrets", scalar(@failed), $include_warnings ? " or problematic" : ""));
	return @failed;
}
# }}}

# TODO: move to vault secrets_store
# _generate_secret_command - create safe command list that performs the requested action on the secret endpoint {{{
sub _generate_secret_command {
	my ($action,$root_path, %plan) = @_;
	my @cmd;
	if ($action eq 'remove') {
		@cmd = ('rm', '-f', $root_path.$plan{path});
		if ($plan{type} eq 'random' && $plan{format}) {
			my ($secret_path,$secret_key) = split(":", $plan{path},2);
			my $fmt_path = sprintf("%s:%s", $root_path.$secret_path, $plan{destination} ? $plan{destination} : $secret_key.'-'.$plan{format});
			push @cmd, '--', 'rm', '-f', $fmt_path;
		}
	} elsif ($plan{type} eq 'x509') {
		my %action_map = (add      => 'issue',
		                  recreate => 'issue',
		                  renew    => 'renew');
		my @names = @{$plan{names} || []};
		push(@names, sprintf("ca.n%09d.%s", rand(1000000000),$plan{base_path})) if $plan{is_ca} && ! scalar(@names);
		@cmd = (
			'x509',
			$action_map{$action},
			$root_path.$plan{path},
			'--ttl', $plan{valid_for} || ($plan{is_ca} ? '10y' : '1y'),
		);
		push(@cmd, '--signed-by', ($plan{signed_by_abs_path} ? '' : $root_path).$plan{signed_by}) if $plan{signed_by};
		if ($action_map{$action} eq 'issue') {
			push(@cmd, '--ca') if $plan{is_ca};
			push(@cmd, '--name', $_) for (@names);
			if (CORE::ref($plan{usage}) eq 'ARRAY') {
				push(@cmd, '--key-usage', $_) for (@{$plan{usage}} ? @{$plan{usage}} : qw/no/);
			}
		} elsif ($action_map{$action} eq 'renew') {
			my ($cert_name) = @names;
			push(@cmd, '--subject', "cn=$cert_name")
				if $cert_name and envset("GENESIS_RENEW_SUBJECT");
			push(@cmd, '--name', $_) for (@names);
			my ($usage) = _get_x509_plan_usage(\%plan);
			if (CORE::ref($usage) eq 'ARRAY') {
				push(@cmd, '--key-usage', $_) for (@{$usage} ? @{$usage} : qw/no/);
			}
		}
	} elsif ($action eq 'renew') {
		# Nothing else supports renew -- return empty action
		debug "No safe command for renew $plan{type}";
		return ();
	} elsif ($plan{type} eq 'random') {
		@cmd = ('gen', $plan{size},);
		my ($path, $key) = split(':',$plan{path});
		push(@cmd, '--policy', $plan{valid_chars}) if $plan{valid_chars};
		push(@cmd, $root_path.$path, $key);
		if ($plan{format}) {
			my $dest = $plan{destination} || "$key-".$plan{format};
			push(@cmd, '--no-clobber') if $action eq 'add' || ($action eq 'recreate' && $plan{fixed});
			push(@cmd, '--', 'fmt', $plan{format}, $root_path.$path, $key, $dest);
		}
	} elsif ($plan{type} eq 'dhparams') {
		@cmd = ('dhparam', $plan{size}, $root_path.$plan{path});
	} elsif (grep {$_ eq $plan{type}} (qw/ssh rsa/)) {
		@cmd = ($plan{type}, $plan{size}, $root_path.$plan{path});
	} elsif ($plan{type} eq 'provided') {
		if (in_controlling_terminal) {
			if ($plan{multiline}) {
				my $file=workdir().'/secret_contents';
				push (@cmd, sub {use Genesis::UI; print "[2A"; mkfile_or_fail($file,prompt_for_block @_); 0}, $plan{prompt}, '--', 'set', split(':', $root_path.$plan{path}."\@$file", 2))
			} else {
				my $op = $plan{sensitive} ? 'set' : 'ask';
				push (@cmd, 'prompt', $plan{prompt}, '--', $op, split(':', $root_path.$plan{path}));
			}
		}
		debug "safe command: ".join(" ", @cmd);
		dump_var plan => \%plan;
		return @cmd;
	} elsif ($plan{type} eq 'uuid') {
		my $version=(\&{"UUID::Tiny::UUID_".$plan{version}})->();
		my $ns=(\&{"UUID::Tiny::UUID_".$plan{namespace}})->() if ($plan{namespace}||'') =~ m/^NS_/;
		$ns ||= $plan{namespace};
		my $uuid = UUID::Tiny::create_uuid_as_string($version, $ns, $plan{name});
		#error "UUID: $uuid ($plan{path})";
		my ($path, $key) = split(':',$plan{path});
		@cmd = ('set', $root_path.$path, "$key=$uuid");
	} else {
		push(@cmd, 'prompt', 'bad request');
		debug "Requested to create safe path for an bad plan";
		dump_var plan => \%plan;
	}
	push(@cmd, '--no-clobber') if ($action eq 'add' || ($plan{fixed} && $action eq 'recreate'));
	debug "safe command: ".join(" ", @cmd);
	dump_var plan => \%plan;
	return @cmd;
}


# _get_plan_paths - list all paths for the given plan {{{
sub _get_plan_paths {
	my $plan = shift;
	my @paths = $plan->{path};
	if ($plan->{type} eq 'random' && $plan->{format}) {
		my ($path,$key) = split(':',$plan->{path},2);
		push @paths, $path.":".($plan->{destination} ? $plan->{destination} : $key.'-'.$plan->{format})." (paired with $plan->{path})";
	}
	return @paths;
}

#}}}
1;
