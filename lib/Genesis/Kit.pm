package Genesis::Kit;
use strict;
use warnings;

use Genesis::Utils;
use Genesis::Run;
use Genesis::Helpers;

sub url {
	my ($self) = @_;

	my $creds = "";
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$creds = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	}
	my ($code, $msg, $data) = curl("GET", "https://api.github.com/repos/genesis-community/$self->{name}-genesis-kit/releases", undef, undef, 0, $creds);
	if ($code == 404) {
		die "Could not find Genesis Kit $self->{name} on Github; does https://github.com/genesis-community/$self->{name}-genesis-kit/releases exist?\n";
	}
	if ($code != 200) {
		die "Could not find Genesis Kit $self->{name} release information; Github returned a ".$msg."\n";
	}

	my $releases;
	eval { $releases = decode_json($data); 1 }
		or die "Failed to read releases information from Github: $@\n";

	if (!@$releases) {
		die "No released versions of Genesis Kit $self->{name} found at https://github.com/genesis-community/$self->{name}-genesis-kit/releases.\n";
	}

	for (map { @{$_->{assets} || []} } @$releases) {
		if ($self->{version} eq 'latest') {
			next unless $_->{name} =~ m/^\Q$self->{name}\E-(.*)\.(tar\.gz|tgz)$/;
			$self->{version} = $1;
		} else {
			next unless $_->{name} eq "$self->{name}-$self->{version}.tar.gz"
			         or $_->{name} eq "$self->{name}-$self->{version}.tgz";
		}
		return ($_->{browser_download_url}, $self->{version});
	}

	die "$self->{name}/$self->{version} tarball asset not found on Github.  Oops.\n";
}

sub path {
	my ($self, $path) = @_;
	$self->extract;
	die "self->extract did not set self->{root}; this is a bug in Genesis!\n"
		unless $self->{root};

	return $self->{root} unless $path;

	$path =~ s|^/+||;
	return "$self->{root}/$path";
}

sub glob {
	my ($self, $glob) = @_;
	$glob =~ s|^/+||;

	$self->extract;
	die "self->extract did not set self->{root}; this is a bug in Genesis!\n"
		unless $self->{root};
	return glob "$self->{root}/$glob";
}

sub has_hook {
	my ($self, $hook) = @_;
	return -f $self->path("hooks/$hook");
}

sub run_hook {
	my ($self, $hook, %opts) = @_;

	die "No '$hook' hook script found\n"
		unless $self->has_hook($hook);

	local %ENV = %ENV;
	$ENV{GENESIS_KIT_NAME}     = $self->{name};
	$ENV{GENESIS_KIT_VERSION}  = $self->{version};
	$ENV{GENESIS_ROOT}         = $opts{root};  # to be replaced with ::Env
	$ENV{GENESIS_ENVIRONMENT}  = $opts{env};   # to be replaced with ::Env
	$ENV{GENESIS_VAULT_PREFIX} = $opts{vault}; # to be replaced with ::Env

	my @args;
	if ($hook eq 'new') {
		# hooks/new root-path env-name vault-prefix
		@args = (
			$opts{root},
			$opts{env},
			$opts{vault},
		);

	} elsif ($hook eq 'secrets') {
		# hook/secret action env-name vault-prefix
		@args = (
			$opts{action},
			$opts{env},
			$opts{vault},
		);

	} elsif ($hook eq 'blueprint') {
		# hooks/blueprint
		@args = ();

	} elsif ($hook eq 'info') {
		# hooks/info env-name
		@args = (
			$opts{env},
		);

	} elsif ($hook eq 'addon') {
		# hooks/addon script [user-supplied-args ...]
		@args = (
			$opts{script},
			@{$opts{args} || []},
		);

	##### LEGACY HOOKS
	} elsif ($hook eq 'prereqs') {
		# hooks/prereqs
		@args = ();

	} elsif ($hook eq 'subkit') {
		# hooks/subkits
		@args = @{$opts{features} || []};

	} else {
		die "Unrecognized hook '$hook'\n";
	}

	chmod 0755, $self->path("hooks/$hook");
	my ($out, $rc) = run({ interactive => $hook eq 'new' },
		'cd "$1"; source .helper; hook=$2; shift 2; ./hooks/$hook "$@"',
		$self->path, $hook, @args);

	if ($hook eq 'new') {
		if ($rc != 0) {
			die "Could not create new env $args[0]\n";
		}
		if (! -f "$args[0].yml") {
			die "Could not create new env $args[0]\n";
		}
		return 1;
	}

	if ($hook eq 'blueprint') {
		if ($rc != 0) {
			die "Could not determine what YAML files to merge from the kit blueprint\n";
		}
		$out =~ s/^\s+//;
		return split(/ /, $out); # FIXME broken
	}

	if ($hook eq 'subkits') {
		if ($rc != 0) {
			die "Could not determine what auxiliary kits (if any) needed to be activated\n";
		}
		$out =~ s/^\s+//;
		return split(/ /, $out); # FIXME broken
	}

	if ($rc != 0) {
		die "Could not run '$hook' hook successfully\n";
	}
	return 1;
}

sub metadata {
	my ($self) = @_;
	return $self->{__metadata} ||= LoadFile($self->path('kit.yml'));
}

sub source_yaml_files {
	my ($self, @features) = @_;

	my @files;
	if ($self->has_hook('blueprint')) {
		local $ENV{GENESIS_REQUESTED_FEATURES} = join(' ', @features);
		@files = $self->run_hook('blueprint');

	} else {
		@files = $self->glob("base/*.yml");
		push @files, map { $self->glob("subkits/$_/*.yml") } @features;
	}

	return @files;
}

sub _legacy_validate_features {
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
	for my $sk (@{$self->meta->{"${label}s"}}) {
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

sub _legacy_process_params {
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

sub _legacy_safe_path_exists {
	return Genesis::Run::check(qw(safe exists), $_[0]);
}

sub _legacy_dereference_param {
	my ($env, $key) = @_;
	my $val = get_key($env, $key);
	die "Unable to resolve '$key' for $env. This must be defined in the environment YAML.\n"
		unless defined $val;
	return $val;
}

sub _legacy_dereference_params {
	my ($cmd, $env) = @_;
	$cmd =~ s/\$\{(.*?)\}/_legacy_dereference_param($env, $1)/ge;
	return $cmd;
}
sub _legacy_safe_commands {
	my ($creds, %options) = @_;
	my @cmds;
	my $force_rotate = ($options{scope}||'') eq 'force';
	my $missing_only = ($options{scope}||'') eq 'add';
	for my $path (sort keys %$creds) {
		if (! ref $creds->{$path}) {
			my $cmd = $creds->{$path};
			$cmd = _legacy_dereference_params($cmd, $options{env});

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
				$cmd = _legacy_dereference_params($cmd, $options{env});

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

sub _legacy_cert_commands {
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

			my @name_flags = map {( "--name", _legacy_dereference_params($_, $options{env}) )} @{$c->{names}};
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

sub _legacy_check_secret {
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
sub _legacy_check_secrets {
	my ($self, %options) = @_;
	my $meta = $self->metadata;

	$options{env} or die "check_secrets() was not given an 'env' option.\n";

	my @missing = ();
	for (_legacy_safe_commands(_legacy_active_credentials($meta, $options{features}||{}),%options)) {
		push @missing, _legacy_check_secret($_, %options);
	}
	for (_legacy_cert_commands(_legacy_active_certificates($meta, $options{features}||{}),%options)) {
		push @missing, _legacy_check_secret($_, %options);
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

sub _legacy_vaultify_secrets {
}

1;
