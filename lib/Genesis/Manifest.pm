package Genesis::Manifest;

use strict;
use warnings;

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
		$self->{env} = undef;
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
	my @prunables = ();
	if ($opts{prune}) {
		@prunables = qw/meta pipeline params kit exodus compilation/;
		push(@prunables, qw{
			resource_pools disk_pools networks vm_types disk_types azs
			vm_extensions
		}) unless $self->{create_env};
	}
	return main::spruce_merge({prune => [@prunables]}, $self->_file(%opts));
}

# Writes a redacted manifest to the specified location
sub write {
	my ($self, $path, %opts) = @_;
	main::mkdir_or_fail(dirname($path));
	main::mkfile_or_fail($path, $self->contents(%opts));
}

# Picks a subpath from the manifest, returning a perl "structure"
sub pick {
	my ($self, $key, %opts) = @_;

	open my $fh, "<", $self->_file(%opts);
		or die "Unable to open manifest for reading: $!\n";
	my $data = JSON::PP->new->allow_nonref->decode(do { local $/; <$fh> });
	close $fh;

	return lookup_in_yaml($data, $key);
}

sub metadata {
	my ($self) = @_;

	my $data = $self->pick('exodus');
	my (@args, %final);

	for my $key (keys %$data) {
		my $val = $data->{$key};

		# convert arrays -> hashes
		if (ref $val eq 'ARRAY') {
			my $h = {};
			for (my $i = 0; $i < @$val; $i++) {
				$h->{$i} = $val->[$i];
			}
			$val = $h;
		}

		# flatten hashes
		if (ref $val eq 'HASH') {
			for my $k (keys %$val) {
				if (ref $val->{$k}) {
					explain "#Y{WARNING:} The kit has specified the genesis.$key.$k\n".
					        "metadata item, but the given value is not a simple scalar.\n".
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
	my @keys= grep {$_ ne ''} Genesis::Run::getlines(
		{onfailure => "Failure while running spruce vaultinfo"},
		'f="$1"; shift; spruce vaultinfo --go-patch "$@" | spruce json | jq -r "$f"',
		'.secrets[].key', $self->source_files);
	return @keys if $opts{include_keys};
	return keys %{{map {(my $p = $_) =~ s/:.*?$//; $p => 1} @keys}};
}

# --- below are "private" support methods not intended to be called directly ---

# Provides the path to, and generates if necessary, an unpruned manifest.  Will
# provide a redacted manifest unless $opts{redact} is falsey.  Will use cached
# version if available unless $opts{rebuild} is truthy.
sub _file {
	my ($self,%opts) = @_;
	my $file = $self->{workdir}."/";
	if ($opts{redact} || ! defined $opts{redact}) {
		$file .= "redacted-manifest.yml";
		$self->_build($file,1) unless -e $file && ! $opts{rebuild};
		debug("#Y{Redacted Manifest generated}: $file");
	} else {
		$file .= "unredacted-manifest.yml";
		$self->_build($file) unless -e $file && ! $opts{rebuild};
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
	my $vault = main::vault_slug($self->{env}).'/'.$self->{type};
	main::mkfile_or_fail($file,0644,<<EOF);
---
meta:
  vault: (( concat "secret/" params.vault || "$vault" ))
exodus: {}
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
exodus:
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

1;

=head1 NAME

Genesis::Manifest - Generates and provides information regarding an environment's manifest.

=head1 CLASS METHODS

=head2 new($env, [%opts])

Creates a new C<Manifest> object for the environment specified by the given
C<$env> C<Genesis::Env> object.

The following options are supported:

=over

=item B<< cloud_config: I<string> >>

The path to the cloud config file.  This file will contain the network details
that are needed when the kit files use the C<(( static_ip ))> operator.
Furthermore, this can be omitted when the using the C<source_files> method, or
the pick method for a subpath that doesn't use the C<(( static_ip ))>
operator.

=back

=head1 INSTANCE METHODS

=head2 source_files([%opts])

Returns the source files used to build the manifest.

The following options are supported:

=over

=item B<< base: I<boolean> >>

If true, includes the base yml files that are generated by B<Genesis> itself
that provide the base foundation on which all manifests are built.

Defaults to I<true>

=item B<< kit: I<boolean> >>

If true, includes the yml files provided by the kit that correspond to the
environments configuration.

Defaults to I<true>

=back

=head2 contents([%opts])

Returns the contents of the generated manifest.  Supports the following options:

=over

=item B<< prune: I<boolean> >>

If true, prunes the supporting branches that contain metadata used in the
construction of the manifest that is not needed or used by BOSH for deployments.

Defaults to I<true>

=item B<< redact: I<boolean> >>

If true, any C<(( vault ... ))> operations will be replaces with C<redacted>
instead of the secrets contain in the given vault path.

Defaults to I<true>

=item B<< rebuild: I<boolean> >>

Normally, the manifests contents are lazily generated when requested and
cached for further use within the lifetime of this object.  If this option is
true, it will force the regeneration of the manifest before returning its contents.

<Defaults to I<false>

=back

=head2 write(path, [%opts])

Writes the contents of the manifest to the specified location, creating any
missing directories as needed.  Takes the same options as C<contents>.

=head2 pick(subpath, [%opts])

Takes a subpath and returns only the values underneath it.  Subpath map keys are
joined with periods, and arrays can be reference by either numeric index or by
key=value format to identify a map object in the array, enclosed in brackets.

=over

=item Example:

    instance_groups[name=concourse].jobs[0].properties.groundcrew

=back

This will return everything under C<groundcrew> under C<properties> for the first
C<job> in the C<instance_group> array element named C<concourse>.

The following options are supported:

=over

=item B<< rebuild:  I<boolean> >>

Force the rebuild of the manifest before picking the subpath value.  See
C<contents> for more details on this option.

Defaults to I<false>

=back

=head2 metadata()

Returns a hashref to the metadata found under the C<genesis> map, collapsing
any arrays and hashes of scalars to <key>.<index> or <key>.<subkey>
respectively.

=head2 secrets([%opts])

Gets the list of vault paths that are in use for the manifest.

=over

=item B<< include_keys: I<boolean> >>

If true, returns each unique path:key requested, otherwise it just returns each
path just once regardless of how many unique keys are requested under that
given path.

Defaults to I<false>

=back

=cut


