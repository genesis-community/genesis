package Genesis::Env::ManifestProvider;

use strict;
use warnings;

use base 'Genesis::Base';

use Genesis;
use JSON::PP qw/encode_json decode_json/;
use Time::HiRes qw/gettimeofday/;
use Data::Dumper;

### Class Methods {{{
# accessor methods for each Manifest type - dynamically built {{{
my $manifest_types = {};
{
	my $search   = __FILE__ =~ s/ManifestProvider.pm/Manifest\/[A-Z]*.pm/r;
	my $lib_base = __FILE__ =~ s/^(.*\/)Genesis\/Env\/ManifestProvider.pm/$1/r;

	for my $pkg_file (glob $search) {
		my $pkg = substr($pkg_file,length($lib_base),length($pkg_file)-length($lib_base)-3);
		$pkg =~ s/\//::/g;
		eval "require $pkg";
		my $method = $pkg->type();
		$manifest_types->{$method} = $pkg;
		no strict 'refs';
		*$method = sub {
			my ($self, %opts) = @_;
			my $type = $method;
			my $subset = delete($opts{subset});
			$type .= "_$subset" if $self->valid_subset($subset);
			$self->{manifests}{$type} //= $pkg->new(
				$self, $subset
			);
			$self->{manifests}{$type}->notify(
				$opts{notification}
			) if $opts{notify} || $opts{notification};
			$self->{manifests}{$type};
		}
	}
}
# }}}
# new - return a new blank ManifestProvider {{{
sub new {
	my ($class, $env) = @_;
	return bless({
		env        => $env,
		manifests  => {},
		deployment => undef
	}, $class);
}

# }}}
# known_types - return the list of known manifest type (dynamically determined) {{{
sub known_types {
	# TODO - return hash with types and descriptions
	# for each entry in %manifest_types - key is type, value->description is description
	my @types = keys %$manifest_types;
	@types = grep {$_ !~ /entombed/} @types
		if ($_[0]->env->use_create_env);
	return [@types]
}

# }}}
# known_subsets - return the list of subset names that can be requested {{{
sub known_subsets {
	# TODO - return hash with subset and description
	# embed descr in _subset_plans
	return [keys %{$_[0]->_subset_plans}];
}
# }}}
# }}}

### Public Instance Methods {{{
# Accessors: env {{{
sub env {$_[0]->{env}}

# }}}
# set_deployment - set the default deployment manifest {{{
sub set_deployment {
	my ($self,$type) = @_;
	bug(
		"Manifest type $type is not deployable"
	) unless $manifest_types->{$type} && $manifest_types->{$type}->deployable;
	$self->{deployment} = $type;
	return $self;
}

# }}}
# deployment - return the manifest builder for the default deployment type {{{
sub deployment {
	my $self = shift;
	my $deployment_type = $self->env->deployment_manifest_type;
	$self->$deployment_type(@_);
}

# }}}
# base_manifest - the manifest to use to look data up (ie not entombified)
sub base_manifest {
	my $self = shift;
	my $lookup_type = $self->_memoize(sub {
		my $self = shift;
		return 'unredacted' if $self->env->use_create_env;
		return 'unredacted' unless $self->env->feature_compatibility('3.0.0');
		return 'unredacted' unless $self->env->lookup('genesis.vaultify', 1);
		return 'vaultified' if (@{$self->unevaluated(notify => 0)->data->{variables}//[]});
		return 'unredacted';
	});

	$self->$lookup_type(@_);
}
# }}}
# reset - reset all stored and cached manifests {{{
sub reset {
	my ($self) = @_;
	delete($self->{manifests}{$_})->reset for (keys %{$self->{manifests}});
	delete($self->{$_}) for (grep {$_ =~ /^__/} keys %$self);
	$self->{deployment}=undef;
	unlink($_) for (glob $self->env->workpath()."/manifest-".$self->env->name."-*");
	return $self;
}

# }}}
# }}}

### Protected Instancre Methods - should only be called by ManifestProvider and Manifest objects {{{
# merge - create a merged manifest {{{
sub merge {
	my ($self,$manifest,$sources,$options,$env_vars) = @_;

	my %option_defaults = (
		eval => 'full',
		multidoc => 1,
		gopatch => 1
	);
	my %options = (%option_defaults,%$options);
	$env_vars //= {};

	$self->env->notify($manifest->get_build_notice)
		if $manifest->has_notice && ! $self->{suppress_notification};

	trace(
		"%s - merging manifest in %s:\n\nSources:\n%s\n\nOptions:\n%s\n\nEnvironment:\n%s",
		ref($manifest),
		$manifest->_generate_file_name(),
		join("\n", map {"  $_"} @$sources),
		join("\n",
			map {"  $_->[0]: $_->[1]"}
			map {$options{$_} ? [$_,$options{$_}] : [$_,"#i{<null>}"]}
			keys %options
		),
		join("\n",
			map {"  $_->[0]: $_->[1]"}
			map {$env_vars->{$_} ? [$_,$env_vars->{$_}] : [$_,"#i{<null>}"]}
			keys %$env_vars
		)
	);

	my ($out, $errors, $warnings) = ();

	my @merge_opts = ();
	push @merge_opts, "--multi-doc" if $options{multidoc};
	push @merge_opts, "--go-patch"  if $options{gopatch};
	push @merge_opts, "--skip-eval" if $options{eval} eq "no";

	pushd $self->env->path;

	if ($options{eval} eq 'adaptive') {
		# TODO - pass in options to adaptive merge
		($out, $warnings) = $self->_adaptive_merge({env => $env_vars}, @$sources);
	} else {
		my $descriptor = sprintf(
			"%s manifest for %s/%s environment",
			$manifest->type, $self->env->name, $self->env->type
		);
		($out,my $rc,my $err) = run({
				onfailure => "Unable to merge $descriptor",
				stderr => "&1",
				env => $env_vars
			},
			'spruce', 'merge', @merge_opts, @$sources
		);
		if ($rc) {
			$errors = $err;
		}
	}
	popd;
	$out =~ s/\s*\z//ms; # no terminating blank lines

	my ($data, $file) = ();
	unless ($errors) {
		$file = $manifest->_generate_file_name();
		debug(
			"saving manifest to %s [%d bytes]",
			$file,
			length($out)
		);
		mkfile_or_fail($file, 0664, $out);
		$data=load_yaml_file($file);
	}

	return ($data, $file, $warnings, $errors);
}

# }}}
# get_subset - create a manifest based on the subset of an existing manifest {{{
sub get_subset {
	my ($self, $manifest, $subset, $req) = @_;
	my $src_manifest = $self->can($manifest->type)->($self);

	# The already-existant alternative source is already resolved at this point
	$self->env->notify($manifest->get_build_notice)
		if $manifest->has_notice && ! $self->{suppress_notification};
	my ($operator,$selection) = %{$self->_subset_plans()->{$subset}};
	if ($req eq 'data') {
		my $src = $src_manifest->data;
		my $data = undef;
		if ($operator eq 'include') {
			$data = {%{$src}{@$selection}};
		} elsif ($operator eq 'exclude') {
			$data = $src; #will be decoupled and pruned down below
		} elsif ($operator eq 'fetch') {
			$data = exists($src->{$selection->{key}})
			? $src->{$selection->{key}}
			: $selection->{default};
		} else {
			bug("Invalid subset operator '$operator'")
		}
		my $new_data = decode_json(encode_json($data)); # deep-copy made easy

		if ($operator eq 'exclude') {
			delete($new_data->{$_}) for (@$selection);
		}
		return ($new_data,undef)
	} else {
		my $src = $src_manifest->file;
		my $file = $manifest->_generate_file_name();
		pushd $self->env->path;
		my @cmd = undef;
		if ($operator eq 'include') {
			@cmd = (
				'fin="$1";fout="$2"; shift 2; spruce merge --skip-eval "$@" "$fin" > "$fout"',
				$src, $file, map {('--cherry-pick', $_)} @{$selection}
			);
		} elsif ($operator eq 'exclude') {
			@cmd = (
				'fin="$1";fout="$2"; shift 2; spruce merge --skip-eval "$@" "$fin" > "$fout"',
				$src, $file, map {('--prune', $_)} @{$selection}
			);
		} elsif ($operator eq 'fetch') {
			@cmd = (
				sprintf(
					'spruce json "$1" | jq \'.%s//%s\' | spruce merge --skip-eval > "$2"',
					$selection->{key}, JSON::PP->new->allow_nonref->encode($selection->{default})
				), $src, $file
			);
		} else {
			bug("Invalid subset operator '$operator'")
		}
		my ($out, $rc, $err) = run(@cmd);
		popd;

		bail (
			"Could not get subset %s from %s manifest: %s",
			$subset, $src_manifest->type, $err
		) if $rc;
		return (undef, $file);
	}
}

# }}}
# initiation_file - create the initiation file for merging kit manifest, return path {{{
sub initiation_file {
	return $_[0]->_memoize( sub {
		return $_[0]->env->_init_yaml_file();
	});
}

# }}}
# kit_files - return the list of files from the kit as per the blueprint {{{
sub kit_files {
	# FIXME: this takes about 2 seconds, which is a noticable delay
	return @{$_[0]->_memoize( sub {
		my $self = shift;
		$self->env->notify({pending => 1}, "determining manifest fragments for merging...")
			unless $self->{suppress_notification};
		my $tstart = gettimeofday;
		my $files = [$self->env->kit_files('absolute')];
		info("#G{done}".pretty_duration(gettimeofday-$tstart,0.5,2));
		return $files;
	})};
}

# }}}
# cloud_config_files - return the cloud config files needed for the manifest build {{{
sub cloud_config_files {
	my ($self, %options) = @_;
	my $optional = $options{optional} ? 1 : 0;
	my $token = "__cloud_config_files_$optional";
	return @{$self->_memoize( $token, sub {
		return [$_[0]->env->_cc_yaml_files($optional)]
	})};
}

# }}}
# environment_files - return the local environment files for the manifest build {{{
sub environment_files {
	return @{$_[0]->_memoize( sub {
		return [$_[0]->env->actual_environment_files()];
	})};
}

# }}}
# conclusion_file - create and return the file that conclused the files to build the manifest {{{
sub conclusion_file {
	return $_[0]->_memoize( sub {
		return $_[0]->env->_cap_yaml_file();
	});
}

# }}}
# full_merge_env - return the full environment variables configuration for merging manifests {{{
sub full_merge_env {
	return $_[0]->_memoize( sub {
		return {$_[0]->env->get_environment_variables('manifest')};
	});
}

# }}}
# valid_subset - returns true if the given subset, errors out otherwise {{{
sub valid_subset {
	my ($self, $subset) = @_;
	return unless defined($subset);
	return 1 if in_array($subset, keys %{$self->_subset_plans});
	bug("Invalid subset '$subset' requested for manifest")
}

# }}}
# vault_paths - list all secrets used in the manifest {{{
sub vault_paths {
	my ($self, %opts) = @_;

	my $file = '';
	if ($opts{data}) {
		$file = tmpfile(
			dir => $self->env->workpath,
			ext => '.yml',
			template => 'manifest-XXXXXXXX'
		);
		save_to_yaml_file($opts{data}, $file);
	} elsif ($opts{file}) {
		$file = $opts{file};
	} elsif ($opts{manifest}) {
		$file = $opts{manifest}->file
	} else {
		$file = $self->unevaluated(
			notify=>!$opts{no_notification}
		)->file;
	}
	pushd $self->env->path;
	my $json = read_json_from(run({
			onfailure => "Unable to determine vault paths from ".$self->env->name." manifest",
			stderr => "&1",
			env => {
				$self->env->get_environment_variables
			}
		},
		'spruce vaultinfo "$1" | spruce json', $file
	));
	popd;

	bail(
		"Expecting spruce vaultinfo to return an array of secrets, got this instead:\n\n".
		Dumper($json)
	) unless ref($json) eq 'HASH' && ref($json->{secrets}) eq 'ARRAY' ;

	my %secrets_map = map {
		(($_->{key} =~ /^\// ? '':'/').$_->{key}, $_->{references})
	} @{$json->{secrets}};
	return \%secrets_map;
}

# }}}
# }}}

### Private Instance Methods {{{
# _subset_plans - defines the available subsets {{{
sub _subset_plans {
	return $_[0]->_memoize( sub {
		return {
			credhub_vars => { include => [qw(variables bosh-variables)]},
			bosh_vars    => { fetch   => {key => 'bosh-variables', default => {}} },
			pruned       => { exclude => [$_[0]->env->prunable_keys]}
		}
	});
};

# }}}
# _adaptive_merge - merge as much as possible, deferring anything unmergible {{{
sub _adaptive_merge {
	my $self = shift;
	my %opts = ref($_[0]) eq 'HASH' ? %{shift()} : ();
	my @files = (@_);

	my ($out,$rc,$err) = run({stderr=>0, %opts}, 'spruce merge --multi-doc --go-patch "$@"', @files);
	return (wantarray ? ($out,$err) : $out) unless $rc;

	my $orig_errors = join("\n", grep {$_ !~ /^\s*$/} lines($err));
	my $contents = '';
	for my $content (map {slurp($_)} @files) {
		$contents .= "\n" unless substr($contents,-1,1) eq "\n";
		$contents .= "---\n" unless substr($content,0,3) eq "---";
		$contents .= $content;
	}
	my $uneval = read_json_from(run(
		{ onfailure => "Unable to merge files without evaluation", stderr => undef, %opts },
		'spruce merge --multi-doc --go-patch --skip-eval "$@" | spruce json', @files
	));

	my $attempt=0;
	while ($attempt++ < 5 and $rc) {
		my @errs = map {$_ =~ /^ - \$\.([^:]*): (.*)$/; [$1,$2]} grep {/^ - \$\./} lines($err);
		for my $err_details (@errs) {
			my ($err_path, $err_msg) = @{$err_details};
			my $val = struct_lookup($uneval, $err_path);
			my $orig_err_path = $err_path;
			my $replaced = 0;
			WANDER: while (! $val) {
				trace "[adaptive_merge] Couldn't find direct dereference error, backtracing $err_path";
				unless ($err_path =~ s/.[^\.]+$//) {
					if ($err_details->[1] =~ /^secret (.*) not found/) {
						my $err_vault_path = $1;
						trace "[adaptive_merge] vault path $err_vault_path not found in merged manifest, looking in original content";
						my $key = $err_details->[0] =~ s/.*\.([^\.]+)$/$1/r;
						my $vault_base = $self->env->secrets_base =~ s/\/$//r;
						my ($source_line, $src_vault_path) = $contents =~ m/($key: \(\(\s*vault (.*?)\s*\)\))/;
						if ($src_vault_path) {
							$src_vault_path =~ s/^meta.vault\s+(["'])/$1$vault_base/;
							$src_vault_path =~ s/["']//g;
							if ($src_vault_path eq $err_vault_path) {
								trace "[adaptive_merge] Found vault path $err_vault_path in original content, deferring";
								my $replacement = $source_line =~ s/\(\( *vault /(( defer vault /r;
								$contents =~ s/\Q$source_line\E/$replacement/sg;
								$replaced = 1;
								last WANDER;
							}
						}
					}
					bug "Internal error: Could not find line causing error '$err_msg' during adaptive merge."
				}
				$val = struct_lookup($uneval, $err_path) || next;
				if (ref($val) eq "HASH") {
					for my $sub_key (keys %$val) {
						if ($val->{$sub_key} && $val->{$sub_key} =~ /\(\( *inject +([^\( ]*) *\)\)/) {
							$err_path = $1;
							trace "[adaptive_merge] Found inject on $sub_key, redirecting to $err_path";
							$val = struct_lookup($uneval, $err_path);
							next WANDER;
						}
					}
				}
				$val = undef; # wasn't what we were looking for, look deeper...
			}

			unless ($replaced) {
				my $spruce_ops=join("|", qw/
					calc cartesian-product concat defer empty file grab inject ips join
					keys load param prune shuffle sort static_ips vault awsparam
					awssecret base64
					/);
				(my $replacement = $val) =~ s/\(\( *($spruce_ops) /(( defer $1 /;
				trace "[adaptive_merge] Resolving $orig_err_path" . ($err_path ne $orig_err_path ? (" => ". $err_path) : "");
				$contents =~ s/\Q$val\E/$replacement/sg;
			}
		}
		my $premerge = mkfile_or_fail($self->env->workpath('premerge.yml'),$contents);
		($out,$rc,$err) = run({stderr => 0, %opts }, 'spruce merge --multi-doc --go-patch "$1"', $premerge);
	}

	bail(
		"Could not merge $self->{name} environment files:\n\n".
		"$err\n\n".
		"Efforts were made to work around resolving the following errors, but if ".
		"they caused the above errors, you may be able to partially resolve this ".
		"issue by using #C{export GENESIS_UNEVALED_PARAMS=1}:\n\n".
		$orig_errors
	) if $rc;

	return (wantarray ? ($out,$orig_errors) : $out)
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
