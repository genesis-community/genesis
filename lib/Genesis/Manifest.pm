package Genesis::Manifest;

use base 'Exporter';
our @EXPORT = qw{
  new
};

use constant {
	REDACTED_FILENAME   => "redacted-manifest.yml",
	UNREDACTED_FILENAME => "unredacted-manifest.yml"
};

use JSON::PP;
use File::Path qw(rmtree);

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
	if ($self && $self->{workdir} && -d $self->{workdir}) {
		rmtree $self->{workdir};
		main::debug("#g{Deleted Manifest workdir:} $self->{workdir}");
	}
}

# Returns the source files used to build the manifest.  Option no_base will
# exclude the genesis-generated base file, and option no_kit will exclude the
# yaml files that come from the kit

sub source_files {
	my ($self,%opts) = @_;
	my @files = ();
	push @files, $self->_base_yml_file unless $opts{no_base};
	push @files, $self->_kit_yaml_files unless $opts{no_kit};						# Will be replaced with Genesis::Kit obj method call
	push @files, main::mergeable_yaml_files($self->{env});							# Will be replaced with Genesis::Env obj method call
	push @files, $self->{cloud_config} if $self->{cloud_config};
	push @files, $self->_finalize_yml_file unless $opts{no_base};
	return @files;
}

# Returns the contents of the manifest.  Option no_prune=1 will result in the
# manifest with ALL the contents including those branches that would be pruned
# prior to deployment
sub contents {
	my ($self,%opts) = @_;
	# Default to producing redacted contents
	local $ENV{REDACT} = (defined($opts{redact}) && !$opts{redact}) ? "" : "1";
	my @prunables = ();
	unless ($opts{'no-prune'}) {
		@prunables = qw/meta pipeline params kit genesis compilation/;
		push(@prunables, qw{
			resource_pools disk_pools networks vm_types disk_types azs
			vm_extensions
		}) unless $self->{create_env};
	}
	return main::spruce_merge({prune => [@prunables]}, $self->file);
}

sub pick {
	my ($self, $path, %opts) = @_;
	my $cmd = 'spruce json "$1" | jq -M "$2"';
	my $format = $opts{'format'} || '';
	$cmd .= ' -c'             if $format eq "JSON";
	$cmd .= ' -r'             if $format eq "PP";
	$cmd .= ' | spruce merge' if $format eq "YAML";
	local $ENV{REDACT} = "";
	my $filter = main::jq_extractor($path);
	$filter .= (" | " . main::jq_embedder($opts{wrap})) if $opts{wrap};
	my ($out,$rc) = run(
    {onfailure => "Could not retrieve '$path' from manifest"},
    $cmd,$self->file,$filter
  );
	$out = JSON::PP->new->allow_nonref->decode($out) unless $format;
	return $out;
}

sub secrets {
	my ($self,%opts) = @_;
	my $yaml_files = join '" "', $self->source_files;
	my @keys= grep {$_ ne ''} Genesis::Run::getlines(
		{onfailure => "Failure while running spruce vaultinfo"},
		'f="$1"; shift; spruce vaultinfo --go-patch "$@" | spruce json | jq -r "$f"',
		'.secrets[].key', @files);
	return @keys unless $opts{'paths-only'};
	return keys %{{map {(my $p = $_) =~ s/:.*?$//; $p => 1} @keys}};
}

# --- below are "private" support methods not intended to be called directly ---
sub file {
	my ($self,$force) = @_;
	my $file = $self->{workdir}."/";
	if ($ENV{REDACT}) {
		$file .= REDACTED_FILENAME;
		$self->_build($file,1) unless -e $file && ! $force;
		debug("#Y{Redacted Manifest generated}");
	} else {
		$file .= UNREDACTED_FILENAME;
		$self->_build($file) unless -e $file && ! $force;
		debug("#Y{Unredacted Manifest generated}");
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
