package Genesis::Legacy;
use strict;
use warnings;

use Genesis::Utils;

sub validate_features {
	my ($self, @features) = @_;
	my $id = $self->id;
	my ($k, $v) = ($self->{name}, $self->{version});
	$k ||= "dev";
	$v = "latest" unless defined $v;

	#### ---- 
	my $label = defined($self->metadata->{subkits}) ? "subkit" : "feature";
	for my $sk (@features) {
		die "You specified a feature without a name\n" unless $sk;
		die "No subkit '$sk' found in kit $id.\n"
			if $label eq "subkit" && ! -d  $self->path("subkits/$sk");
	}

	my %requested_features = map { $_ => 1 } @features;
	for my $sk (@{$self->metadata->{"${label}s"}}) {
		if ($sk->{choices}) {
			my $matches = 0;
			my ($min_matches,$max_matches) = (1,1);
			if (defined $sk->{pick}) {
				if ($sk->{pick} =~ /^(?:(\d+)|(\d+)?-(\d+)?)$/) {
					($min_matches,$max_matches) = (defined $1) ? ($1,$1) : ($2, $3);
				} else {
					$! = 2; die "There is a problem with kit $id: $sk->{type} pick invalid.  Please contact the kit author for a fix";
				}
			}
			my @choices;
			for my $choice (@{$sk->{choices}}) {
				push @choices, $choice->{$label} if defined $choice && defined $choice->{$label};
				if (! defined $choice->{$label}){
					$min_matches = 0;
				} elsif ($requested_features{$choice->{$label}}) {
					$matches++;
				}
			}
			my $choices = join(", ", map { "'$_'" } @choices);
			if ($max_matches && $matches > $max_matches) {
				die "You selected too many ${label}s for your $sk->{type}. Should be only one of $choices\n";
			}
			if ($min_matches && $matches < $min_matches) {
				die "You must select a $label to provide your $sk->{type}. Should be one of $choices\n";
			}
		}
	}
}

sub process_params {
	my ($self, %opts) = @_;
	# for legacy!
	$opts{kit}     = $self->name;
	$opts{version} = $self->version;
	$opts{params}  = $self->metadata->{params} || {};

	my @answers;
	my $resolveable_params = {
		"params.vault_prefix" => $opts{vault_prefix}, # for backwards compatibility
		"params.vault" => $opts{vault_prefix},
		"params.env" => $opts{env}
	};
	for my $feature ("base", @{$opts{features}}) {
		next unless defined $opts{params}{$feature} && @{$opts{params}{$feature}};
		my $kit_params_file = $feature eq "base" ? "base/params.yml" : "subkits/$feature/params.yml";
		my $defaults = LoadFile(kit_file($opts{kit}, $opts{version}, $kit_params_file, 1));
		for my $q (@{$opts{params}{$feature}}) {
			my $answer;
			my $vault_path;
			# Expand any values from default and examples for vault prefix
			foreach (qw(description ask default example validate err_msg)) {
				$q->{$_} =~ s/\$\{([^}]*)\}/resolve_params_ref($1,$resolveable_params)/ge if defined($q->{$_});
			}
			if (defined($q->{validate}) && $q->{validate} eq 'vault_path') {
				if (defined($q->{default})) {
					while ($q->{default} =~ s#/[^/]+/\.\./#/#) {};
				}
				if (defined($q->{example})) {
					while ($q->{example} =~ s#/[^/]+/\.\./#/#) {};
				}
			}
			if ($q->{ask}) {
				$q->{type} ||= "string";
				print "\n";
				if ($q->{param}) {
					print csprintf("#y{Required parameter:} #W{$q->{param}}\n\n");
				} else {
					$vault_path = "secret/$opts{vault_prefix}/$q->{vault}";
					print csprintf("#y{Secret data required} -- will be stored in Vault under #W{$vault_path}\n\n");
				}
				chomp $q->{description};
				print "$q->{description}\n";
				print "(e.g. $q->{example})\n" if defined $q->{example};
				if ($q->{param}) {
					my $type = $q->{type};
					if (defined($q->{validate}) && $q->{validate} =~ /^vault_path(_and_key)?$/ && ! vaulted()) {
						print csprintf("#y{Warning:} Cannot validate vault paths when --no-secrets option specified");
					}
					if ($type eq 'boolean') {
						$answer = prompt_for_boolean($q->{ask},$q->{default});
					} elsif ($type eq 'string') {
						$answer = prompt_for_line($q->{ask},$q->{label},$q->{default},$q->{validate},$q->{err_msg});
					} elsif ($type =~ m/^(block|multi-?line)$/) {
						$answer = prompt_for_block($q->{ask},$q->{label},$q->{default});
					} elsif ($type eq 'list') {
						$answer = prompt_for_list('line',$q->{ask},$q->{label},$q->{min_count},$q->{max_count},$q->{validate},$q->{err_msg});
					} elsif ($type =~ m/^(block|multi-?line)-list$/) {
						$answer = prompt_for_list('block',$q->{ask},$q->{label},$q->{min_count},$q->{max_count});
					} elsif ($type =~ m/^(multi-)?choice$/) {
						my ($choices,$labels)=([],[]);
						if (ref($q->{validate}) eq 'ARRAY') {
							foreach (@{$q->{validate}}) {
								if (ref($_) eq 'ARRAY') {
									push @$choices, $_->[0];
									push @$labels, $_->[1];
								} else {
									push @$choices, $_;
									push @$labels, undef;
								}
							}
						}
						if ($type eq 'choice') {
							$answer = prompt_for_choice($q->{ask},$choices,$q->{default},$labels,$q->{err_msg});
						} else {
							$answer = prompt_for_choices($q->{ask},$choices,$q->{min_count},$q->{max_count},$labels,$q->{err_msg});
						}
					} else {
						die "Unsupported type '$type' for parameter '$q->{param}'. Please contact your kit author for a fix.\n";
					}
					print "\n";
				} else {
					my ($path, $key) = split /:/, $vault_path;
					if ($q->{type} =~ /^(boolean|string)$/) {
						Genesis::Run::interact(
							{onfailure => "Failed to save data to $vault_path in Vault"},
							'safe prompt "$1" -- "$2" "$3" "$4"',
							$q->{ask}, ($q->{echo} ? "ask" : "set"), $path, $key
						);
					} elsif ($q->{type} eq "multi-line") {
						$answer = prompt_for_block($q->{ask});
						my $tmpdir = workdir;
						open my $fh, ">", "$tmpdir/param" or die "Could not write to $tmpdir/param: $!\n";
						print $fh $answer;
						close $fh;
						Genesis::Run::do_or_die(
							"Failed to save data to $vault_path in Vault",
							'safe set "$1" "${2}@${3}/param"',
							$path, $key, $tmpdir
						);
					} else {
						die "Unsupported parameter type '$q->{type}' for $q->{vault}. Please contact your kit author for a fix.\n";
					}
					print "\n";
					next;
				}
			}
			my @values;
			my $is_default = 0;
			if (! $q->{ask}) {
				$is_default = 1;
				if (defined $q->{param}) {
					$q->{params} = [$q->{param}];
				}
				for my $p (@{$q->{params}}) {
					# Should we throw an error here if the default value is
					# a spruce operator like (( param ))?
					push @values, { $p => $defaults->{params}{$p} };
					$resolveable_params->{"params.$p"} = $defaults->{params}{$p};
				}
			} else {
				push @values, { $q->{param} => $answer };
				$resolveable_params->{"params.$q->{param}"} = $answer;
			}

			push @answers, {
				comment => $q->{description},
				example => $q->{example},
				values  => \@values,
				default => $is_default,
			};
		}
	}
	return \@answers;
}

sub safe_path_exists {
	return Genesis::Run::check(qw(safe exists), $_[0]);
}

sub dereference_param {
	my ($env, $key) = @_;
	my $val = get_key($env, $key);
	die "Unable to resolve '$key' for $env. This must be defined in the environment YAML.\n"
		unless defined $val;
	return $val;
}

sub dereference_params {
	my ($cmd, $env) = @_;
	$cmd =~ s/\$\{(.*?)\}/dereference_param($env, $1)/ge;
	return $cmd;
}
sub safe_commands {
	my ($creds, %options) = @_;
	my @cmds;
	my $force_rotate = ($options{scope}||'') eq 'force';
	my $missing_only = ($options{scope}||'') eq 'add';
	for my $path (sort keys %$creds) {
		if (! ref $creds->{$path}) {
			my $cmd = $creds->{$path};
			$cmd = dereference_params($cmd, $options{env});

			if ($cmd =~ m/^(ssh|rsa)\s+(\d+)(\s+fixed)?$/) {
				my $safe = [$1, $2, "secret/$options{prefix}/$path"];
				push @$safe, "--no-clobber", "--quiet" if ($3 && !$force_rotate) || $missing_only;
				push @cmds, $safe;

			} elsif ($cmd =~ m/^dhparams?\s+(\d+)(\s+fixed)?$/) {
				my $safe = ['dhparam', $1, "secret/$options{prefix}/$path"];
				push @$safe, "--no-clobber", "--quiet" if ($2 && !$force_rotate) || $missing_only;
				push @cmds, $safe;

			} else {
				die "unrecognized credential type: `$cmd'\n";
			}
		} elsif ('HASH' eq ref $creds->{$path}) {
			for my $attr (sort keys %{$creds->{$path}}) {
				my $cmd = $creds->{$path}{$attr};
				$cmd = dereference_params($cmd, $options{env});

				if ($cmd =~ m/^random\s+(\d+)(\s+fmt\s+(\S+)(\s+at\s+(\S+))?)?(\s+allowed-chars\s+(\S+))?(\s+fixed)?$/) {
					my ($len, $format, $destination, $valid_chars, $fixed) = ($1, $3, $5, $7, $8);
					my @allowed_chars = ();
					if ($valid_chars) {
						@allowed_chars = ("--policy", $valid_chars);
					}
					my $safe = ['gen', $len, @allowed_chars, "secret/$options{prefix}/$path", $attr];
					push @$safe, "--no-clobber", "--quiet" if ($fixed && !$force_rotate) || $missing_only;
					push @cmds, $safe;
					if ($format) {
						$destination ||= "$attr-$format";
						my $safe = ["fmt", $format , "secret/$options{prefix}/$path", $attr, $destination];
						push @$safe, "--no-clobber", "--quiet" if ($fixed && !$force_rotate) || $missing_only;
						push @cmds, $safe;
					}

				} else {
					die "unrecognized credential type: `$cmd'\n";
				}
			}
		} else {
			die "unrecognized datastructure for $path. Please contact your kit author\n";
		}
	}

	return @cmds;
}

sub cert_commands {
	my ($certs, %options) = @_;
	my @cmds;
	my $force_rotate = ($options{scope}||'') eq 'force';
	my $missing_only = ($options{scope}||'') eq 'add';
	for my $path (sort keys %$certs) {
		my @cmd = (
			"x509",
			"issue",
			"secret/$options{prefix}/$path/ca",
			"--name", "ca.$path",
			"--ca");
		push @cmd, "--no-clobber", "--quiet" if !$force_rotate; # All CA certs are considered kept
		push @cmds, \@cmd;

		for my $cert (sort keys %{$certs->{$path}}) {
			next if $cert eq "ca";
			my $c = $certs->{$path}{$cert};

			die "Required 'names' value missing for cert at $path/$cert.\n" unless $c->{names}[0];
			my $cn = $c->{names}[0];
			$c->{valid_for} ||= "1y";

			my @name_flags = map {( "--name", dereference_params($_, $options{env}) )} @{$c->{names}};
			my @cmd = (
				"x509",
				"issue",
				"secret/$options{prefix}/$path/$cert",
				"--ttl", $c->{valid_for},
				@name_flags,
				"--signed-by", "secret/$options{prefix}/$path/ca");
			push @cmd, "--no-clobber", "--quiet" if $missing_only || $c->{fixed};
			push @cmds, \@cmd;
		}
	}
	return @cmds;
}

sub check_secret {
	my ($cmd, %options) = @_;
	my (@keys);
	my $type = $cmd->[0];
	my $path = $cmd->[2];
	if ($type eq 'x509') {
		if (grep {$_ eq '--signed-by'} @$cmd) {
			$type = "certificate";
			@keys = qw(certificate combined key);
		} else {
			$type = "CA certificate";
			@keys = qw(certificate combined crl key serial);
		}
	} elsif ($type eq 'rsa') {
		@keys = qw(private public);
	} elsif ($type eq 'ssh') {
		@keys = qw(private public fingerprint);
	} elsif ($type eq 'dhparam') {
		@keys = qw(dhparam-pem);
	} elsif ($type eq 'gen') {
		$type = 'random';
		my $path_offset = $cmd->[1] eq '-l' ? 3 : 2;
		$path_offset += 2 if $cmd->[$path_offset] eq '--policy';
		$path = $cmd->[$path_offset];
		@keys = ($cmd->[$path_offset + 1]);
	} elsif ($type eq 'fmt') {
		$type = 'random/formatted';
		@keys = ($cmd->[4]);
	} else {
		die "Unrecognized credential or certificate command: '".join(" ", @$cmd)."'\n";
	}
	return map {["[$type]", "$path:$_"]} grep {!safe_path_exists("$path:$_")} @keys;
}
sub check_secrets {
	my ($self, %options) = @_;
	my $meta = $self->metadata;

	$options{env} or die "check_secrets() was not given an 'env' option.\n";

	my @missing = ();
	for (safe_commands(active_credentials($meta, $options{features}||{}),%options)) {
		push @missing, check_secret($_, %options);
	}
	for (cert_commands(active_certificates($meta, $options{features}||{}),%options)) {
		push @missing, check_secret($_, %options);
	}
	if (@missing) {
		my $suf = scalar(@missing) == 1 ? '' : 's';
		printf "Missing %d credential%s or certificate%s:\n  * %s\n",
			scalar(@missing), $suf, $suf,
			join ("\n  * ", map {join " ", @$_} @missing);
		return 1;
	} else {
		print "All credentials and certificates present.\n";
		return 0;
	}
}

# generate (and optionally rotate) credentials.
#
## just rotate credentials
# vaultify_secrets $kit_metadata,
#                  target       => "my-vault",
#                  env          => "us-east-sandbox",
#                  prefix       => "us/east/sandbox",
#                  scope        => 'rotate'; # or scope => '' or undef
#
## generate all credentials (including 'fixed' creds)
# vaultify_secrets $kit_metadata,
#                  target       => "my-vault",
#                  env          => "us-east-sandbox",
#                  prefix       => "us/east/sandbox",
#                  scope        => 'force';
#
## generate only missing credentials
# vaultify_secrets $kit_metadata,
#                  target       => "my-vault",
#                  env          => "us-east-sandbox",
#                  prefix       => "us/east/sandbox",
#                  scope        => 'add';
#
sub vaultify_secrets {
	my ($meta, %options) = @_;
	$options{env} or die "vaultify_secrets() was not given an 'env' option.\n";

	my $creds = active_credentials($meta, $options{features} || {});
	if (%$creds) {
		explain " - auto-generating credentials (in secret/$options{prefix})...\n";
		for (safe_commands $creds, %options) {
			Genesis::Run::interact(
				{onfailure => "Failure autogenerating credentials."},
				'safe', @$_
			);
		}
	} else {
		explain " - no credentials need to be generated.\n";
	}

	my $certs = active_certificates($meta, $options{features} || {});
	if (%$certs) {
		explain " - auto-generating certificates (in secret/$options{prefix})...\n";
		for (cert_commands $certs, %options) {
			Genesis::Run::interact(
				{onfailure => "Failure autogenerating certificates."},
				'safe', @$_
			);
		}
	} else {
		explain " - no certificates need to be generated.\n";
	}
}

sub new_environment {
	my ($self) = @_;
	my ($k, $kit, $version) = ($self->{kit}, $self->{kit}->name, $self->{kit}->version);
	my $meta = $k->metadata;

	$k->run_hook('prereqs') if $k->has_hook('prereqs');

	my @features = prompt_for_env_features($self);
	my $params = process_params($k,
		env          => $self->{name},
		vault_prefix => $self->{prefix},
		features     => \@features,
	);
	if ($k->has_hook('params')) {
		$params = $k->run_hook('params', params => $params);
	}

	## create the environment file.
	my $file = "$self->{name}.yml";
	my ($parent, %existing_info);
	if ($self->{name} =~ m/-/) { # multi-level environment; make/use a top-level
		($parent = $file) =~ s/-.*\.yml/.yml/;
		if (-e $parent) {
			explain "Using existing #C{$parent} file as base config.";
			%existing_info = %{LoadFile($parent)};
		}
	}

	open my $fh, ">", $file or die "Couldn't write to $file: $!";
	print $fh "---";
	print $fh "\nkit:\n" if (
		!%existing_info ||
		$existing_info{kit}{name} ne $kit ||
		$existing_info{kit}{version} ne $version ||
		!same($existing_info{kit}{features}||[],\@features)
	);
	if (!%existing_info || $existing_info{kit}{name} ne $kit) {
		print $fh "  name:     $kit\n";
		error "#y{WARNING:} $parent specifies a different kit name ($existing_info{kit}{name})"
			if %existing_info;
	}
	if (!%existing_info || $existing_info{kit}{version} ne $version) {
		print $fh "  version:  $version\n";
		error "#y{WARNING:} $parent specifies a different kit version ($existing_info{kit}{version})"
			if %existing_info;
	}

	print $fh "  features:\n";
	print $fh "    - (( replace ))\n";
	print $fh "    - $_\n" foreach (@features);
	print $fh <<EOF;

params:
  env:   $self->{name}
  vault: $self->{prefix}
EOF
	if (defined($ENV{GENESIS_BOSH_ENVIRONMENT})) {
		print $fh <<EOF;
  bosh:  $ENV{GENESIS_BOSH_ENVIRONMENT}
EOF
	}

	for my $param (@$params) {
		print $fh "\n";
		my $indent = "  # ";
		if (defined $param->{comment}) {
			for my $line (split /\n/, $param->{comment}) {
				print $fh "${indent}$line\n";
			}
		}
		if (defined $param->{example}) {
			print $fh "${indent}(e.g. $param->{example})\n";
		}

		$indent = $param->{default} ? "  #" : "  ";

		for my $val (@{$param->{values}}) {
			my $k = (keys(%$val))[0];
			# if the value is a spruce operator, we know it's a string, and don't need fancy encoding of the value
			# this helps us not run into issues resolving the operator
			my $v = $val->{$k};
			if (defined $v && ! ref($v) && $v =~ m/^\(\(.*\)\)$/) {
				print $fh "${indent}$k: $v\n";
				next;
			}
			my $tmpdir = workdir;
			open my $tmpfile, ">", "$tmpdir/value_formatting";
			print $tmpfile encode_json($val);
			close $tmpfile;
			open my $spruce, "-|", "spruce merge $tmpdir/value_formatting";

			for my $line (<$spruce>) {
				chomp $line;
				next unless $line;
				next if $line eq "---";
				print $fh "${indent}$line\n";
			}
			close $spruce;
			die "Unable to convert JSON to spruce-compatible YAML. This is a bug\n"
				if $? >> 8;
		}
	}
	close $fh;
	explain "Created #C{$file} environment file";
}

sub prompt_for_env_features {
	my ($self) = @_;
	my ($kit, $version) = ($self->{kit}{name}, $self->{kit}{version});
	my $meta = $self->{kit}->metadata;

	my @features;
	my $features_meta = $meta->{features} || $meta->{subkits} || [];
	my @meta_key = (defined $meta->{features}) ? 'feature' : 'subkit';
	foreach my $feature (@$features_meta) {
		my $prompt = $feature->{prompt}."\n";
		if (exists $feature->{choices}) {
			my (@choices,@labels,$default);
			foreach (@{$feature->{choices}}) {
				push @choices, $_->{feature} || $_->{subkit};
				push @labels,  $_->{label};
				$default = ($_->{feature} || $_->{subkit}) if $_->{default} && $_->{default} =~ /^(y(es)?|t(rue)?|1)$/i;
			}
			if (exists $feature->{pick}) {
				die "There is a problem with kit $kit/$version: $feature->{type} pick invalid.  Please contact the kit author for a fix"
					unless $feature->{pick} =~ /^\d+(-\d+)?$/;
				my ($min, $max) =  ($feature->{pick} =~ /-/)
					? split('-',$feature->{pick})
					: ($feature->{pick},$feature->{pick});
				my $selections = grep {$_} prompt_for_choices($prompt,\@choices,$min,$max,\@labels);
				push @features, @$selections;
			} else {
				push @features, grep {$_} (prompt_for_choice($prompt,\@choices,$default,\@labels));
			}
		} else {
			push(@features, ($feature->{feature} || $feature->{subkit})) if  prompt_for_boolean($prompt,$feature->{default});
		}
	}

	if ($self->{kit}->has_hook('subkits')) {
		@features = $self->{kit}->run_hook('subkits', features => \@features);
	}
	Genesis::Legacy::validate_features($self->{kit}, @features);
	return @features;
}

sub active_credentials {
	my ($meta, $features) = @_;

	my $active = {};
	for my $sub (('base', @$features)) {
		next unless $meta->{credentials}{$sub};
		for my $path (keys %{ $meta->{credentials}{$sub} }) {
			if (exists $active->{$path} && ref $meta->{credentials}{$sub}{$path}) {
				for my $k (keys %{ $meta->{credentials}{$sub}{$path} }) {
					$active->{$path}{$k} = $meta->{credentials}{$sub}{$path}{$k};
				}
			} else {
				$active->{$path} = $meta->{credentials}{$sub}{$path};
			}
		}
	}
	return $active;
}

sub active_certificates {
	my ($meta, $features) = @_;

	my $active = {};
	for my $sub (('base', @$features)) {
		next unless $meta->{certificates}{$sub};
		for my $path (keys %{ $meta->{certificates}{$sub} }) {
			if (exists $active->{$path} && ref $meta->{certificates}{$sub}{path}) {
				for my $k (keys %{ $meta->{certificates}{$sub}{$path} }) {
					$active->{$path}{$k} = $meta->{certificates}{$sub}{$path}{$k};
				}
			} else {
				$active->{$path} = $meta->{certificates}{$sub}{$path};
			}
		}
	}
	return $active;
}

sub resolve_params_ref {
	my ($key,$references) = @_;
	die("\$\{$key\} referenced but not found -- perhaps it hasn't been defined yet.  Contact your Kit author for a bugfix.\n")
		unless exists($references->{$key});
	return $references->{$key};
}

1;
