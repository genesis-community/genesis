package Genesis::Kit::Secrets::Parser::FromKit;
use strict;
use warnings;

use Genesis;
use Genesis::Kit::Secret;

use base 'Genesis::Kit::Secrets::Parser';

sub new {
	my ($class, $env, $metadata, @features) = @_;

	my $self= bless({
		env => $env,
		metadata => $metadata,
		features => [@features],
	},$class);
}

### Instance Methods {{{

# secrets_definitions - return the definitions structure for the kit
sub get_secrets_definitions {
	$_[0]->_memoize(sub {
    trace "Parsing plans for kit secrets";
		$_[0]->_get_kit_secrets()
	});
}

sub plans {
	my ($self, %opts) = @_;
	my $plans = $self->get_secrets_definitions();

	# Sort the plans in order of application (check for cyclical ca relations)
	my $groups = {};
	push(@{$groups->{$plans->{$_}{type}} ||= []}, $_) for (sort(keys(%$plans)));

	my @ordered_plans = _process_x509_plans(
		$plans,
		delete($groups->{x509}),
		$opts{root_ca_path},
		$opts{validate});

	# Add in all the other types that don't require prerequesites
	for my $type (sort(keys %$groups)) {
		for my $path (sort @{$groups->{$type}}) {
			my $ok = 1;
			if ($opts{validate}) {
				my $validate_sub = "_validate_${type}_plan";
				$ok = (\&{$validate_sub})->($plans,$path,\@ordered_plans) if exists(&{$validate_sub});
			}
			push @ordered_plans, $plans->{$path} if $ok;
		}
	}
	return [@ordered_plans];

	# TODO: extract filter as a pipe-able class method(?)
	if ($opts{filter} && @{$opts{filter}}) {
		my @explicit_paths;
		my @filtered_paths;
		my $filtered = 0;
		for my $filter (@{$opts{filter}}) { #and each filter with previous results
			if (grep {$_->{path} eq $filter} @ordered_plans) { # explicit path
				push @explicit_paths, $filter;
				next;
			}
			my @or_paths;
			@filtered_paths = map {$_->{path}} @ordered_plans # start will all possible paths
				unless $filtered++; # initialize on first use
			while (defined $filter) {
				my @paths;
				($filter, my $remainder) = $filter =~ /(.*?)(?:\|\|(.*))?$/; # or
				debug "Parsing left half of an or-filter: $filter || $remainder" if $remainder;

				if ($filter =~ /(.*?)(!)?=(.*)$/) { # plan properties
					my ($key,$negate,$value) = ($1,$2,$3);
					@paths = map {$_->{path}} grep {defined($_->{$key}) && ($negate ? $_->{$key} ne $value : $_->{$key} eq $value)} @ordered_plans;
					debug "Parsing plan properties filter: $key = '$value' => ".join(", ",@paths);

				} elsif ($filter =~ m'^(!)?/(.*?)/(i)?$') { # path regex
					my ($match,$pattern,$reopt) = (($1 || '') ne '!', $2, ($3 || ''));
					debug "Parsing plan path regex filter: path %s~ /%s/%s", $match?'=':'!', $pattern, $reopt;
					my $re; eval "\$re = qr/\$pattern/$reopt";
					@paths = map {$_->{path}} grep {$match ? $_->{path} =~ $re : $_->{path} !~ $re} @ordered_plans;

				} else {
					bail "\n#R{[ERROR]} Could not understand path filter of '%s'", $filter;
				}
				@or_paths = uniq(@or_paths, @paths); # join together the results of successive 'or's
				$filter = $remainder;
			}
			my %and_paths = map {($_,1)} @filtered_paths;
			@filtered_paths = grep {$and_paths{$_}} @or_paths; #and together each feature
		}
		my %filter_map = map {($_,1)} (@filtered_paths, @explicit_paths);
		@ordered_plans = grep { $filter_map{$_->{path}} } (@ordered_plans);
	}
	trace "Completed parsing plans for kit secrets";
	return @ordered_plans;
}

### Private Instance Methods

# _get_kit_secrets - get the raw secrets from the kit.yml file {{{
sub _get_kit_secrets {
	my $self = shift;

	my @secrets;
	for my $feature ('base', @{$self->{features}}) {
		if ($self->{metadata}{certificates}{$feature}) {
			for my $path (keys %{ $self->{metadata}{certificates}{$feature} }) {
				if ($path =~ ':') {
					push @secrets, Genesis::Kit::Secret->reject(
            "Bad Request:\n- Path cannot contain colons",
						$path => 'x509', $self->{metadata}{certificates}{$feature}{$path} 
					);
					next;
				}
				my $data = $self->{metadata}{certificates}{$feature}{$path};
        if (ref($data) ne 'HASH') {
					push @secrets, Genesis::Kit::Secret->reject(
            "Badly formed x509 request:\n- expecting certificate specification in the form of a hash map",
						$path => 'x509', $self->{metadata}{certificates}{$feature}{$path} 
					);
					next;
				}
				for my $k (keys %$data) {
					my $ext_path = "$path/$k";

					if (ref($data->{$k}) ne 'HASH') {
						my $reftype = ref($data->{$k});
						my $value = $reftype ? $reftype." reference" : "'$data->{$k}'";
						push @secrets, Genesis::Kit::Secret->reject(
							"Badly formed x509 request:\nExpecting hash map, got $value",
							$ext_path => 'x509', {
								%{$data->{$k}},
								base_path => $path
							}
						);
						next;
					};

					# In-the-wild POC conflict fix for cf-genesis-kit v1.8.0-v1.10.x
          $data->{$k}{signed_by} = "application/certs/ca"
            if ($data->{$k}{signed_by} || '') eq "base.application/certs.ca";

					push @secrets, Genesis::Kit::Secret->build(
						$ext_path => 'x509',
						%{$data->{$k}},
						base_path => $path,
					);
				}
			}
		}
		if ($self->{metadata}{credentials}{$feature}) {
			for my $path (keys %{ $self->{metadata}{credentials}{$feature} }) {
				if ($path =~ ':') {
					push @secrets, Genesis::Kit::Secret->reject(
						"Bad credential request:\n- Path cannot contain colons",
						$path => '', $self->{metadata}{credentials}{$feature}{$path}
					);
					next;
				}
				my $data = $self->{metadata}{credentials}{$feature}{$path};
				if (ref($data) eq "HASH") {
					for my $k (keys %$data) {
						if ($k =~ ':') {
							push @secrets, Genesis::Kit::Secret->reject(
								"Bad credential request:\n- Key cannot contain colons",
								$path => 'unknown', $data,
							);
							next;
						}
						my $cmd = $data->{$k};
						if ($cmd =~ m/^random\b/) {
							if ($cmd =~ m/^random\s+(\d+)(\s+fmt\s+(\S+)(\s+at\s+(\S+))?)?(\s+allowed-chars\s+(\S+))?(\s+fixed)?$/) {
								push @secrets, Genesis::Kit::Secret->build(
									"$path:$k"  => 'random',
									size        => $1,
									format      => $3,
									destination => $5,
									valid_chars => $7,
									fixed       => (!!$8),
								);
							} else {
								push @secrets, Genesis::Kit::Secret->reject(
									"Bad random password request:\n".
									"- Expected usage: random <size> [fmt <format> [at <key>]] [allowed-chars <chars>] [fixed]\n".
									"  Got: $cmd",
									"$path:$k" => 'random', $cmd
								);
							}
						} elsif ($cmd =~ m/^uuid\b/) {
							if ($cmd =~ m/^uuid(?:\s+(v[1345]|time|md5|random|sha1))?(?:\s+namespace (?:([a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12})|(dns|url|oid|x500)))?(?:\s+name (.*?))?(\s+fixed)?$/i) {
								push @secrets, Genesis::Kit::Secret->build(
									"$path:$k"  => 'uuid',
									version     => uc($1||"v4"),
									namespace   => $2 || ($3 ? "NS_".uc($3) : undef),
									name        => $4,
									fixed       => (!!$5)
								);
							} else {
								push @secrets, Genesis::Kit::Secret->reject(
									"Bad UUID request:\n".
									"- Expected usage: uuid [v1|time|v3|md5|v4|random|v5|sha1] ".
									"[namespace (dns|url|oid|x500|<UUID namespace>] [name <name>] [fixed]\n".
									"  Got: $cmd",
									"$path:$k" => 'uuid', $cmd
								);
							}
						} else {
							push @secrets, Genesis::Kit::Secret->reject(
								"Bad credential request:\n- Bad generate-password format '$cmd'",
									"$path:$k" => 'random', $cmd
								);
						}
					}
				} elsif ($data =~ m/^(ssh|rsa)\s+(\d+)(\s+fixed)?$/) {
					push @secrets, Genesis::Kit::Secret->build($path => $1, size=> $2, fixed => (!!$3));
				} elsif ($data =~ m/^dhparams?\s+(\d+)(\s+fixed)?$/) {
					push @secrets, Genesis::Kit::Secret->build($path => 'dhparams', size => $1, fixed => (!!$2));
				} elsif ($data =~ m/^random .?$/) {
					push @secrets, Genesis::Kit::Secret->reject(
						"Bad credential request:\n- Random password request for a path must be specified per key in a hashmap",
						$path => 'random', $data
					);
				} elsif ($data =~ m/^uuid .?$/) {
          push @secrets, Genesis::Kit::Secret->reject(
						"Bad credential request:\n- UUID request for a path must be specified per key in a hashmap",
						$path => 'uuid', $data
					);
				} else {
          push @secrets, Genesis::Kit::Secret->reject(
						"Bad credential request:\n- Unrecognized request '$data'",
						$path => 'unknown', $data
					);
				}
			}
		}
		if ($self->{metadata}{provided}{$feature}) {
      my $reftype = lc(ref($self->{metadata}{provided}{$feature}));
			if ($reftype eq 'hash') {
				for my $path (keys %{ $self->{metadata}{provided}{$feature} }) {
          my $data = $self->{metadata}{provided}{$feature}{$path} || '';
					if ($path =~ ':') {
            push @secrets, Genesis::Kit::Secret->reject(
							"Bad provided secret description:\n- Path cannot contain colons",
							$path => 'provided', $data
						);
						next;
					}
          my $reftype = lc(ref($data));
          if (! $reftype || $reftype ne 'hash') {
            push @secrets, Genesis::Kit::Secret->reject(
							"Bad provided secrets path:\n- Expecting hashmap, got '".($reftype || $data)."'",
							$path => 'provided', $data
						);
						next;
					}
					my $type = $data->{type} || 'generic';
					if ($type eq 'generic') {
						if (!defined($data->{keys}) || ref($data->{keys}) ne 'HASH') {
              push @secrets, Genesis::Kit::Secret->reject(
								"Bad generic provided secret description:\n- Missing 'keys' hash", 
							$path => 'provided', $data
							);
							next;
						}
						for my $k (keys %{$data->{keys}}) {
							if ($k =~ ':') {
								push @secrets, Genesis::Kit::Secret->reject(
									"Bad generic provided secret description:\n- Key cannot contain colons",
									$path => 'provided', $k
								);
								next;
							}
							push @secrets, Genesis::Kit::Secret->build(
								"$path:$k" => 'provided',
								subtype    => $data->{keys}{$k}{type},
								sensitive  => (defined($data->{keys}{$k}{sensitive}) ? !!$data->{keys}{$k}{sensitive} : 1),
								multiline  => (!!$data->{keys}{$k}{multiline}),
								prompt     => $data->{keys}{$k}{prompt} || "Value for $path $k",
								fixed      => (!!$data->{keys}{$k}{fixed})
							);
						}
					} else {
						push @secrets, Genesis::Kit::Secret->reject(
							"Bad provided secrets description:\n- Unrecognized type '$type'; expecting one of: generic",
							$path => 'provided', $data
						);
					}
				}
			} elsif ($reftype) {
        push @secrets, Genesis::Kit::Secret->reject(
					"Bad provided secrets feature block:\n- Expecting hashmap of paths, got $reftype",
					$feature => 'provided', $self->{metadata}{provided}{$feature}
				);
			} else {
        push @secrets, Genesis::Kit::Secret->reject(
					"Bad provided secrets feature block:\n- Expecting hashmap of paths, got '$self->{metadata}{provided}{$feature}'",
					$feature => 'provided', $self->{metadata}{provided}{$feature}
				);
			}
		}
	}

	my %plans;
	$plans{$_->{path}} = $_ for (@secrets);
	return \%plans;
}

# _process_x509_plans - determine signing changes, add defaults and specify build order {{{
sub _process_x509_plans {
	my ($plans, $paths, $root_ca_path, $validate) = @_;

	my @paths = @{$paths || []};
	my $base_cas = {};
	for (grep {$_ =~ /\/ca$/ || ($plans->{$_}{is_ca}||'') =~ 1} @paths) {
		$plans->{$_}{is_ca} = 1;
		push(@{$base_cas->{$plans->{$_}{base_path}} ||= []}, $_);
	}

	for my $base_path (keys %$base_cas) {
		next unless my $count = scalar(@{$base_cas->{$base_path}});
		my ($base_ca, $err);
		if ($count == 1) {
			# Use the ca for the base path
			$base_ca = $base_cas->{$base_path}[0];
		} elsif (grep {$_ eq "$base_path/ca"} @{$base_cas->{$base_path}}) {
			# Use the default ca if there's more than one
			$base_ca = "$base_path/ca";
		} else {
			# Ambiguous - flag this further down
			$err = "Unspecified/ambiguous signing CA";
		}

		my @signable_certs = grep {!$plans->{$_}{is_ca}
		                        &&  $plans->{$_}{base_path} eq $base_path
		                        && !$plans->{$_}{signed_by}
		                          } @paths;
		for (@signable_certs) {
			if ($err) {
				$plans->{$_}{type} = "error";
				$plans->{$_}{error} = "Ambiguous or missing signing CA"
			} else {
				$plans->{$_}{signed_by} = $base_ca;
			}
		}
	}

	my $signers = {};
	for (@paths) {
		my $signer = $plans->{$_}{signed_by} || '';
		push (@{$signers->{$signer} ||= []}, $_);
	}
	$signers->{$_} = [sort @{$signers->{$_}}] for (keys %$signers);
	_sign_unsigned_x509_plans($signers->{''}, $plans, $root_ca_path );

	my @ordered_plans;
	my $target = '';
	while (1) {
		_sign_x509_plans($target,$signers,$plans,\@ordered_plans,$validate);
		$target = _next_signer($signers);
		last unless $target;
	}

	# Find unresolved signage paths
	for (grep {$plans->{$_}{type} eq 'x509' && !$plans->{$_}{__processed}} sort(keys %$plans)) {
		$plans->{$_}{type} = "error";
		$plans->{$_}{error} = "Could not find associated signing CA";
		push(@ordered_plans, $plans->{$_})
	}

	return @ordered_plans;
}

# }}}
# _sign_unsigned_x509_plans - sign unsigned plans with the root CA if present, otherwise self-signed {{{
sub _sign_unsigned_x509_plans {
	my ($cert_paths, $plans, $root_ca) = @_;
	for my $path (@{$cert_paths||[]}) {
		next unless $plans->{$path}{type} eq 'x509' && !$plans->{$path}{signed_by};
		if ($root_ca) {
			$plans->{$path}{signed_by} = $root_ca;
			$plans->{$path}{signed_by_abs_path} = 1;
		} else {
			$plans->{$path}{self_signed} = 1;
		}
	}
}

# }}}
# _sign_x509_plans - process the certs in order of signer {{{
sub _sign_x509_plans {
	my ($signer,$certs_by_signer,$src_plans,$ordered_plans,$validate) = @_;
	if ($signer) {
		if (! grep {$_->{path} eq $signer} (@$ordered_plans)) {
			my ($idx) = grep {$certs_by_signer->{$signer}[$_] eq $signer} ( 0 .. scalar(@{$certs_by_signer->{$signer}})-1);
			if (defined($idx)) {
				# I'm signing myself - must be a CA
				unshift(@{$certs_by_signer->{$signer}}, splice(@{$certs_by_signer->{$signer}}, $idx, 1));
				$src_plans->{$signer}{self_signed} = 2; #explicitly self-signed
				$src_plans->{$signer}{signed_by} = "";
				$src_plans->{$signer}{is_ca} = 1;
			}
		}
	}
	while (my $cert = shift(@{$certs_by_signer->{$signer}})) {
		if (grep {$_->{path} eq $cert} (@$ordered_plans)) {
			# Cert has been added already - bail
			$src_plans->{$cert} ||= {};
			$src_plans->{$cert}{type}  = 'error';
			$src_plans->{$cert}{error} = 'Cyclical CA signage detected';
			return;
		}
		$src_plans->{$cert}{__processed} = 1;
		push(@$ordered_plans, $src_plans->{$cert})
			if ((!$validate) || _validate_x509_plan($src_plans,$cert,$ordered_plans));
		_sign_x509_plans($cert,$certs_by_signer,$src_plans,$ordered_plans,$validate)
			if scalar(@{$certs_by_signer->{$cert} || []});
	}
}

# }}}
# _next_signer - determine next signer so none are orphaned {{{
sub _next_signer {
	my $signers = shift;
	my @available_targets = grep {scalar(@{$signers->{$_}})} sort(keys %$signers);
	while (@available_targets) {
		my $candidate = shift @available_targets;
		# Dont use a signer if its signed by a remaining signer
		next if grep {$_ eq $candidate} map { @{$signers->{$_}} } @available_targets;
		return $candidate;
	}
	return undef;
}

# }}}
# _validate_x509_plan - check the cert plan is valid {{{
sub _validate_x509_plan {
	my ($plans,$cert_name, $ordered_plans) = @_;

	my %cert = %{$plans->{$cert_name}};
	my $err = "";

	# Most of this has been moved 
		# TODO: This needs a full plan to validate, not just a single cert
		$err .= "\n- CA Common Name Conflict - can't share CN '".@{$cert{names}}[0]."' with signing CA"
			if (
				(ref($plans->{$cert{signed_by}})||'' eq "HASH") &&
				$plans->{$cert{signed_by}}{names} &&
				ref($cert{names}) eq 'ARRAY' &&
				ref($plans->{$cert{signed_by}}{names}) eq 'ARRAY' &&
				@{$cert{names}}[0] eq @{$plans->{$cert{signed_by}}{names}}[0]
			);
	
	if ($err) {
		$plans->{$cert_name} = {%cert, type => 'error', error => "Bad X509 certificate request: $err"};
		push @$ordered_plans, $plans->{$cert_name};
		return undef;
	}
	return 1;
}

# }}}
# _validate_kit_secret - list keys expected for a given kit secret {{{
sub _validate_kit_secret {
	my ($scope,$plan,$secret_values,$root_path,$plans) = @_;

	# Existance
	my ($path,$key) = split(':', $root_path.$plan->{path});
	$path =~ s#^/?(.*?)/?$#$1#;
	$path =~ s#/{2,}#/#g;
	my $values = $secret_values->{$path};
	return ('missing') unless defined($values)
	                       && ref($values) eq 'HASH'
	                       && (!defined($key) || defined($values->{$key}));

	my @keys = _expected_kit_secret_keys(%$plan);
	return (
		'error',
		sprintf("Cannot process secret type '%s': unknown type",$plan->{type})
	) unless @keys;

	my $errors = join("\n", map {sprintf("%smissing key ':%s'", _checkbox(0), $_)} grep {! exists($values->{$_})} @keys);
	return ('missing',$errors) if $errors;
	return ('ok') unless $scope eq 'validate';
	return ('ok', '') if $plan->{type} eq 'provided';

	my $validate_sub=sprintf("_validate_%s_secret", $plan->{type});
	return ('ok', '') unless (exists(&{$validate_sub}));

	my ($results, @validations) = (\&{$validate_sub})->($path, $key, $plan, $secret_values, $plans, $root_path);
	my $show_all_messages = ! envset("GENESIS_HIDE_PROBLEMATIC_SECRETS");
	my %priority = ('error' => 0, 'warn' => 1, 'ok' => 2);
	my @results_levels = sort {$priority{$a}<=>$priority{$b}}
	                     uniq('ok', map {$_ ? ($_ =~ /^(error|warn)$/ ? $_ : 'ok') : 'error'}
	                                map {$_->[0]}
	                                values %$results);
	return (
		$results_levels[0],
		join("\n", map {_checkbox($_->[0]).$_->[1]}
		           grep {$show_all_messages || $priority{$_->[0]} <= $priority{$results_levels[0]}}
		           map {$results->{$_}}
		           grep {exists $results->{$_}}
		           @validations));
}


# _expected_kit_secret_keys - list keys expected for a given kit secret {{{ # TODO: move to secrets store...?  Is this store or secret specific?
sub _expected_kit_secret_keys {
	my (%plan) = @_;
	my @keys;
	my $type = $plan{type};
	if ($type eq 'x509') {
		@keys = qw(certificate combined key);
		push(@keys, qw(crl serial)) if $plan{is_ca};
	} elsif ($type eq 'rsa') {
		@keys = qw(private public);
	} elsif ($type eq 'ssh') {
		@keys = qw(private public fingerprint);
	} elsif ($type eq 'dhparams') {
		@keys = qw(dhparam-pem);
	} elsif ($type =~ /^(random|provided|uuid)$/) {
		my (undef,$key) = split(":",$plan{path});
		@keys = ($key);
		push(@keys, $plan{destination} || "$key-".$plan{format})
			if $plan{format};
	}
	return @keys;
}

sub _memoize {
	my ($self, $initialize, @args) = @_;
	(my $token = (caller(1))[3]) =~ s/^.*::/__/;
	return $self->{$token} if defined($self->{$token});
	$self->{$token} = $initialize->($self);
}

1;