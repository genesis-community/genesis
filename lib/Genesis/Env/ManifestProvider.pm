package Genesis::Env::ManifestProvider;

use strict;
use warnings;

use base 'Genesis::Base';

use Genesis;
use JSON::PP qw/encode_json decode_json/;

# Dynamically build accessor methods
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

# Class Methods
sub new {
	my ($class, $env) = @_;
	return bless({
		env        => $env,
		manifests  => {},
		deployment => undef
	}, $class);
}

sub known_types {
	# TODO - return hash with types and descriptions
	# for each entry in %manifest_types - key is type, value->description is description
	my @types = keys %$manifest_types;
	@types = grep {$_ !~ /entombed/} @types
		if ($_[0]->env->use_create_env);
	return [@types]
}

sub known_subsets {
	# TODO - return hash with subset and description
	# embed descr in _subset_plans
	return [keys %{$_[0]->_subset_plans}];
}

# Instance Methods

sub reset {
	my ($self) = @_;
	delete($self->{manifests}{$_})->reset for (keys %{$self->{manifests}});
	delete($self->{$_}) for (grep {$_ =~ /^__/} keys %$self);
	$self->{deployment}=undef;
	unlink($_) for (glob $self->env->workpath()."/manifest-".$self->env->name."-*");
	return $self;
}

sub env {$_[0]->{env}}

sub set_deployment {
	my ($self,$type) = @_;
	bug(
		"Manifest type $type is not deployable"
	) unless $manifest_types->{$type} && $manifest_types->{$type}->deployable;
	$self->{deployment} = $type;
	return $self;
}

sub deployment {
	my $self = shift;

	$self->{deployment} //= $self->env->use_create_env ? 'unredacted' : 'entombed';
	my $deployment_type = $self->{deployment};
	$self->$deployment_type(@_);
}

# Protected methods - should only be called by ManifestProvider and Manifest objects
sub merge {
	my ($self,$manifest,$sources,$options,$env_vars) = @_;

	my %option_defaults = (
		eval => 'full',
		multidoc => 1,
		gopatch => 1
	);
	my %options = (%option_defaults,%$options);
	$env_vars //= {};

	$self->env->_notify($manifest->get_build_notice) if $manifest->has_notice;
	
	trace(
		"%s - merging manifest\n\nSources:\n%s\n\nOptions:\n%s\n\nEnvironment:\n%s",
		ref($manifest),
		join("\n", map {"  $_"} @$sources),
		join("\n",
			map {"  $_->[0]: $_->[1]"}
			map {$options{$_} ? [$_,$options{$_}] : [$_,"#i{<null>}"]}
			keys %options
		),
		join("\n",
			map {"  $_->[0]: $_->[1]"}
			map {$options{$_} ? [$_,$options{$_}] : [$_,"#i{<null>}"]}
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
		($out, $warnings) = $self->env->adaptive_merge({env => $env_vars}, @$sources);
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
	$out =~ s/[\r\n ]*\z/\n/ms; # Ensure output is terminated with a newline, but no blank lines

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

sub get_subset {
	my ($self, $manifest, $subset, $req) = @_;
	my $src_manifest = $self->can($manifest->type)->($self);

	# The already-existant alternative source is already resolved at this point
	$self->env->_notify($manifest->get_build_notice) if $manifest->has_notice;

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

		bail (
			"Could not get subset %s from %s manifest: %s",
			$subset, $src_manifest->type, $err
		) if $rc;
		return (undef, $file);
	}
}

sub initiation_file {
	return $_[0]->_memoize( sub {
		return $_[0]->env->_init_yaml_file();
	});
}

sub kit_files {
	# FIXME: this takes about 2 seconds, which is a noticable delay
	return @{$_[0]->_memoize( sub {
		$_[0]->env->_notify("Determining manifest fragments for merging....");
		return [$_[0]->env->kit_files('absolute')];
	})};
}

sub cloud_config_files {
	my ($self, %options) = @_;
	my $optional = $options{optional} ? 1 : 0;
	my $token = "__cloud_config_files_$optional";
	return @{$self->_memoize( $token, sub {
		return [$_[0]->env->_cc_yaml_files($optional)]
	})};
}

sub environment_files {
	return @{$_[0]->_memoize( sub {
		return [$_[0]->env->actual_environment_files()];
	})};
}

sub conclusion_file {
	return $_[0]->_memoize( sub {
		return $_[0]->env->_cap_yaml_file();
	});
}

sub full_merge_env {
	return $_[0]->_memoize( sub {
		return {$_[0]->env->get_environment_variables('manifest')};
	});
}

sub _subset_plans {
	return $_[0]->_memoize( sub {
		return { 
			credhub_vars => { include => [qw(variables bosh-variables)]},
			bosh_vars    => { fetch   => {key => 'bosh-variables', default => {}}},
			pruned       => { exclude => [$_[0]->env->prunable_keys]}
		}
	});
};

sub valid_subset {
	my ($self, $subset) = @_;
	return unless defined($subset);
	return 1 if in_array($subset, keys %{$self->_subset_plans});
	bug("Invalid subset '$subset' requested for manifest")
}

1;
