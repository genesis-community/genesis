package Genesis::Legacy;
use strict;
use warnings;

use Genesis;
use Genesis::UI;
use JSON::PP qw/encode_json decode_json/;

sub same {
	my ($a, $b) = @_;
	die "Arguments are not arrays" unless ref($a) eq 'ARRAY' && ref($b) eq 'ARRAY';
	return 0 unless scalar(@$a) == scalar(@$b);
	return 0 unless join(',',map {length} @$a) eq join(',',map {length} @$b);
	return 0 unless join("\0", @$a) eq join("\0",@$b);
	return 1;
}

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
					$self->kit_bug("$sk->{type} pick is invalid");
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
	# $self is a Genesis::Kit object
	my ($self, %opts) = @_;
	my $env = $opts{env} or die "process_params() was not given an 'env' option.\n";

	# for legacy!
	$opts{kit}     = $self->name;
	$opts{version} = $self->version;
	$opts{params}  = $self->metadata->{params} || {};
	$opts{secrets_base} = $env->secrets_base;

	my @answers;
	my $resolveable_params = {
		"params.vault_prefix" => $env->secrets_slug, # for backwards compatibility
		"params.vault" => $env->secrets_slug,
		"params.env" => $env->name,
	};
	for my $feature ("base", @{$opts{features}}) {
		next unless defined $opts{params}{$feature} && @{$opts{params}{$feature}};
		my $defaults = load_yaml_file($self->path($feature eq "base" ? "base/params.yml"
		                                                             : "subkits/$feature/params.yml"));
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
					$vault_path = "$opts{secrets_base}$q->{vault}";
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
						$self->kit_bug("Unsupported type '$type' for parameter '$q->{param}'!!");
					}
					print "\n";
				} else {
					my ($path, $key) = split /:/, $vault_path;
					if ($q->{type} =~ /^(boolean|string)$/) {
						$env->vault->query(
							{ interactive => 1, onfailure => "Failed to save data to $vault_path in Vault" },
							'prompt', $q->{ask}, '--', ($q->{echo} ? "ask" : "set"), $path, $key
						);

					} elsif ($q->{type} eq "multi-line") {
						$answer = prompt_for_block($q->{ask});
						my $tmpdir = workdir;

						open my $fh, ">", "$tmpdir/param" or die "Could not write to $tmpdir/param: $!\n";
						print $fh $answer;
						close $fh;

						$env->vault->query(
							{ onfailure => "Failed to save data to $vault_path in Vault" },
							'set', $path, "${key}\@${tmpdir}/param"
						);

					} else {
						$self->kit_bug("Unsupported parameter type '$q->{type}' for $q->{vault}!!");
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

sub dereference_param {
	my ($env, $key) = @_;

	my $default = undef;
	if ($key =~ m/^maybe:/) {
		$key =~ s/^maybe://;
		$default = "";
	}
	my $val = $env->lookup($key, $default);
	die "Unable to resolve '$key' for ".$env->name.". This must be defined in the environment YAML.\n"
		unless defined $val;
	return $val;
}

sub dereference_params {
	my ($cmd, $env) = @_;
	$cmd =~ s/\$\{(.*?)\}/dereference_param($env, $1)/ge;
	return $cmd;
}

sub run_param_hook {
	my ($env,$params,@features) = @_;

	my $hook = $env->kit->path("hooks/params");
	return $params unless -f $hook;
	chmod(0755,$hook) unless -x $hook;

	my $dir = workdir;
	my $infile = "$dir/in";
	open my $ifh, ">", $infile or die "Unable to write to $infile: $!\n";
	print $ifh encode_json($params);
	close $ifh;

	my $rc = run(
		{interactive => 1, env => {
			GENESIS => $ENV{GENESIS_CALLBACK_BIN},
			GENESIS_ENVIRONMENT_NAME => $env->name,
			GENESIS_VAULT_PREFIX => $env->secrets_slug }},
		$hook, "$dir/in", "$dir/out", @features
	);
	die "\nNew environment creation cancelled.\n" if $rc == 130;
	die "\nError running params hook for ".$env->kit->id.". Contact your kit author for a bugfix.\n" if $rc;

	# FIXME: get a better error message when json fails to load
	open my $ofh, "<", "$dir/out";
	my @json = <$ofh>;
	close $ofh;
	return decode_json(join("\n",@json));
}

sub new_environment {
	my ($self) = @_;
	$self->setup_hook_env_vars('new');

	my ($k, $kit, $version) = ($self->{kit}, $self->{kit}->name, $self->{kit}->version);
	my $meta = $k->metadata;

	$k->run_hook('prereqs', env => $self) if $k->has_hook('prereqs');

	my @features = prompt_for_env_features($self);
	my $params = process_params($k,
		env          => $self,
		features     => \@features,
	);
	$params = run_param_hook($self, $params, @features);

	## create the environment file
	my $file = "$self->{name}.yml";
	my ($parent, %existing_info);
	if ($self->{name} =~ m/-/) { # multi-level environment; make/use a top-level
		($parent = $file) =~ s/-.*\.yml/.yml/;
		if (-e $parent) {
			explain("Using existing #C{$parent} file as base config.");
			%existing_info = %{load_yaml_file($parent)};
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

	# genesis block
	my $genesis_out = '';
	$genesis_out .= sprintf "  env:                %s\n",$self->name;
	$genesis_out .= sprintf "  bosh_env:           %s\n", $ENV{BOSH_ALIAS}
		if $ENV{BOSH_ALIAS} && ($ENV{BOSH_ALIAS} ne $ENV{GENESIS_ENVIRONMENT});
	$genesis_out .= sprintf "  min_version:        %s\n",$ENV{GENESIS_MIN_VERSION}
		if $ENV{GENESIS_MIN_VERSION};
	$genesis_out .= sprintf "  secrets_path:       %s\n",$ENV{GENESIS_SECRETS_SLUG}
		if $ENV{GENESIS_SECRETS_SLUG_OVERRIDE};
	$genesis_out .= sprintf "  root_ca_path:       %s\n",$ENV{GENESIS_ENV_ROOT_CA_PATH}
		if $ENV{GENESIS_ENV_ROOT_CA_PATH};
	$genesis_out .= sprintf "  secrets_mount:      %s\n",$ENV{GENESIS_SECRETS_MOUNT}
		if $ENV{GENESIS_SECRETS_MOUNT_OVERRIDE};
	$genesis_out .= sprintf "  exodus_mount:       %s\n",$ENV{GENESIS_EXODUS_MOUNT}
		if $ENV{GENESIS_EXODUS_MOUNT_OVERRIDE};
	$genesis_out .= sprintf "  ci_mount:           %s\n",$ENV{GENESIS_CI_MOUNT}
		if $ENV{GENESIS_CI_MOUNT_OVERRIDE};
	$genesis_out .= sprintf "  credhub_exodus_env: %s\n",$ENV{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE}
		if $ENV{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE};

	my $overpad = [sort {length($a) <=> length($b)} ($genesis_out =~ /:\s+/g)]->[0];
	$genesis_out =~ s/$overpad/: /g;
	print  $fh "\ngenesis:\n$genesis_out";

	my $params_out = '';
	for my $param (@$params) {
		$params_out .= "\n";
		my $indent = "  # ";
		if (defined $param->{comment}) {
			for my $line (split /\n/, $param->{comment}) {
				$params_out .= "${indent}$line\n";
			}
		}
		if (defined $param->{example}) {
			$params_out .= "${indent}(e.g. $param->{example})\n";
		}

		$indent = $param->{default} ? "  #" : "  ";

		for my $val (@{$param->{values}}) {
			my $k = (keys(%$val))[0];
			# if the value is a spruce operator, we know it's a string, and don't need fancy encoding of the value
			# this helps us not run into issues resolving the operator
			my $v = $val->{$k};
			if (defined $v && ! ref($v) && $v =~ m/^\(\(.*\)\)$/) {
				$params_out .= "${indent}$k: $v\n";
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
				$params_out .= "${indent}$line\n";
			}
			close $spruce;
			die "Unable to convert JSON to spruce-compatible YAML. This is a bug\n"
				if $? >> 8;
		}
	}
	$params_out ||= " {}\n";
	print $fh "\nparams:$params_out";
	close $fh;
	explain("Created #C{$file} environment file\n");
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
				$feature->{pick} =~ /^\d+(-\d+)?$/
					or $self->kit_bug("$feature->{type} pick invalid!!");

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
		@features = $self->{kit}->run_hook('subkit', features => \@features);
	}
	Genesis::Legacy::validate_features($self->{kit}, @features);
	return @features;
}

sub resolve_params_ref {
	my ($key,$references) = @_;
	die("\$\{$key\} referenced but not found -- perhaps it hasn't been defined yet.  Contact your Kit author for a bugfix.\n")
		unless exists($references->{$key});
	return $references->{$key};
}

1;
