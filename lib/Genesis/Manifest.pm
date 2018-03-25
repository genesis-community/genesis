package Genesis::Manifest;

use JSON::PP;
use File::Path qw(rmtree);
use File::Basename;

use Genesis::Run;
use Genesis::Utils;

sub new {
	my ($class,$env,%opts) = @_;

	my $self = {
		env               => $env,													# Will be replaced with a Genesis::Env object when available.
		type              => delete $opts{type} || main::deployment_suffix($env),	# Genesis::Env will have this in the future
		cloud_config      => delete $opts{'cloud-config'},
		create_env        => main::is_create_env($env),
		workdir           => workdir("$env-manifest"),
		files             => undef
	};

	# Special circumstance if a create-env to populate a special cloud-config
	if ($self->{create_env}) {
		$self->{cloud_config} = $self->{workdir}."/cloud.yml";
		main::write_stemcell_data($self->{cloud_config});
	}
	return bless($self,$class);
}

sub DESTROY {
	my ($self) = @_;
	if ($self) {
		if ($self->{workdir} && -d $self->{workdir}) {
			rmtree $self->{workdir};
			debug("#g{Deleted Manifest workdir:} $self->{workdir}");
		}
		$self->env = undef if $self->env; #important once env becomes an object
	}
}

sub source_files {
	my ($self,%opts) = @_;
	# Default to having everything
	$opts{$_} = 1 for grep {! defined $opts{$_}} qw/base kit/;
	my @files = ();
	push @files, $self->_base_yml_file     if $opts{base};
	push @files, $self->_kit_yaml_files    if $opts{kit};						# Will be replaced with Genesis::Kit obj method call
	push @files, main::mergeable_yaml_files($self->{env});							# Will be replaced with Genesis::Env obj method call
	push @files, $self->{cloud_config}     if $self->{cloud_config};
	push @files, $self->_finalize_yml_file if $opts{base};
	return @files;
}

# Returns the contents of the manifest.  Option no_prune=1 will result in the
# manifest with ALL the contents including those branches that would be pruned
# prior to deployment
sub contents {
	my ($self,%opts) = @_;
	# Default to producing pruned, redacted contents
	$opts{$_} = 1 for grep {! defined $opts{$_}} qw/prune redact/;
	local $ENV{REDACT} = $opts{redact} ? "1" : "";
	my @prunables = ();
	if ($opts{prune}) {
		@prunables = qw/meta pipeline params kit genesis compilation/;
		push(@prunables, qw{
			resource_pools disk_pools networks vm_types disk_types azs
			vm_extensions
		}) unless $self->{create_env};
	}
	return main::spruce_merge({prune => [@prunables]}, $self->_file($opts{rebuild}));
}

# Writes a redacted manifest to the specified location
sub write {
	my ($self, $path, %opts) = @_;
	main::mkdir_or_fail(dirname($path));
	mkfile_or_fail($path, $self->contents(%opts));
}

# Picks a subpath from the manifest, returning a perl "structure"
sub pick {
	my ($self, $subpath, %opts) = @_;
	my $cmd = 'spruce json "$1" | jq -M "$2"';
	local $ENV{REDACT} = "";
	my $filter = main::jq_extractor($subpath);
	my ($out,$rc) = run(
    {onfailure => "Could not retrieve '$subpath' from manifest"},
    $cmd,$self->_file($opts{rebuild}),$filter
  );
	$out = JSON::PP->new->allow_nonref->decode($out);
	return $out;
}

sub metadata {
	my ($self) = @_;

	my $data = $self->pick('genesis');
	my (@args, %final);

	for my $key (keys %$data) {
		my $val = $data->{$key};

		# convert arrays -> hashes
		if (ref $val eq 'ARRAY') {
			my $h = {};
			for (my $i = 0; $i < @$val; $i++) {
				$h{$i} = $val->[$i];
			}
			$val = $h;
		}

		# flatten hashes
		if (ref $val eq 'HASH') {
			for my $k (keys %$val) {
				if (ref $val->{$k}) {
					explain "#Y{WARNING:} The kit has specified the genesis.$key.$k\n".
					        "metadata item, but the given value is not a simple scalar.\n";
					        "Ignoring this metadata value.\n";
					next;
				}
				$final{"$key.$k"} = $val->{$k};
			}

		} else {
			$final{$key} = $data->{$key};
		}
	}

	return \%final;
}

sub secrets {
	my ($self,%opts) = @_;
	my $yaml_files = join '" "', $self->source_files;
	my @keys= grep {$_ ne ''} Genesis::Run::getlines(
		{onfailure => "Failure while running spruce vaultinfo"},
		'f="$1"; shift; spruce vaultinfo --go-patch "$@" | spruce json | jq -r "$f"',
		'.secrets[].key', @files);
	return @keys if $opts{include_keys};
	return keys %{{map {(my $p = $_) =~ s/:.*?$//; $p => 1} @keys}};
}

# --- below are "private" support methods not intended to be called directly ---

# Provides the path to, and generates if necessary, an unpruned manifest that
# is redacted (or not) according to $ENV{REDACT}
sub _file {
	my ($self,$force) = @_;
	my $file = $self->{workdir}."/";
	if ($ENV{REDACT}) {
		$file .= "redacted-manifest.yml";
		$self->_build($file,1) unless -e $file && ! $force;
		debug("#Y{Redacted Manifest generated}: $file");
	} else {
		$file .= "unredacted-manifest.yml";
		$self->_build($file) unless -e $file && ! $force;
		debug("#Y{Unredacted Manifest generated}: $file");
	}
	return $file
}

sub _build{
	my ($self,$file,$redacted) = @_;
	$redacted ||= "";
	local $ENV{REDACT} = $redacted;
	main::mkfile_or_fail ($file, 0644, main::spruce_merge({}, $self->source_files));
}

sub _base_yml_file {
	my ($self) = @_;
	my $file = $self->{workdir} . "/base.yml";
	main::mkfile_or_fail($file,0644,<<EOF);
---
meta:
  vault: (( concat "secret/" params.vault || "nowhere" ))
genesis: {}
params:
  name: (( concat params.env "-$self->{type}" ))
name: (( grab params.name ))
EOF
	return $file;
}

sub _finalize_yml_file {
	my ($self) = @_;
	my $file = $self->{workdir} . "/finalize.yml";
	main::mkfile_or_fail($file,0644,<<EOF);
---
genesis:
  kit_name:    (( grab kit.name    || "unknown" ))
  kit_version: (( grab kit.version || "unknown" ))
  vault_base:  (( grab meta.vault ))
EOF
	return $file;
}

sub _kit_yaml_files {
	my ($self) = @_;
	unless ($self->{_cached_kit_yaml_files}) {
		# Cache the kit files so we don't have to validate the kit every time.
		$self->{_cached_kit_yaml_files} = [main::kit_yaml_files($self->{env})];
	}
	return @{$self->{_cached_kit_yaml_files}};
}
# }}} end package Genesis::Manifest
