package Genesis::Env::Manifest;

use strict;
use warnings;

use base "Genesis::Base";

use Genesis;
use Genesis::Term;
use POSIX qw/strftime/;

# Constructors
sub new {
	my ($class, $builder, $subset) = @_;

	my $manifest = bless({
		builder => $builder,
		subset => $subset,
		file => undef,
		data => undef
	}, $class);

	my $cached_file = $manifest->_generate_file_name;
	if (-f $cached_file) {
		trace "Loading cached manifest file $cached_file";
		$manifest->set_file($cached_file);
	}
	$manifest;
}

# Instance Methods

sub builder {$_[0]->{builder}}
sub env     {$_[0]->{builder}->env}

sub type {
	my $self = shift;
	my $type = (ref($self)||$self) =~ s/.*::([^:]*)$/\l$1/r;
	$type =~ s/(?<=\w)([A-Z])/_\l$1/g;
	$type;
}
sub label {
	$_[0]->type =~ s/_/ /gr;
}

sub subset {
	$_[0]->{subset} // '';
}

sub redacted {
	bug("redacted: Not implemented for %s manifest types", $_[0]->label);
}

sub data {
	return $_[0]->_memoize('data', sub {
		my $self = shift;
		if ($self->has_file) {
			trace "Loading prebuild %s manifest for %s", $self->type, $self->env->name;
			return $self->_load_file();
		}

		my ($data,$file) = ();
		if ($self->is_subset) {
			($data, $file) = $self->_get_subset('data');
		} else {
			($data, $file) = $self->_merge();
		}
		$self->set_file($file) if $file;
		return $data;
	});
}

sub file {
	return $_[0]->_memoize('file', sub {
		my $self = shift;
		return $self->_save_data_to_file($self->{data}) if ($self->has_data);

		my ($data,$file) = ();
		if ($self->is_subset) {
			($data, $file) = $self->_get_subset('file');
		} else {
			($data, $file) = $self->_merge();
		}
		$self->set_data($data) if $data;
		return $file;
	});
}


sub deployable {0}

sub has_data   {defined($_[0]->{data})}
sub has_file   {defined($_[0]->{file})}

sub set_data   {$_[0]->{data} = $_[1]}
sub set_file   {$_[0]->{file} = $_[1]}

sub write_to   {copy_or_fail($_[0]->file,$_[1])}
sub reset {
	my $self = shift;
	trace(
		"Resetting %s manifest to allow rebuild (data: %s, filename: %s, file: %s)",
		$self->label,
		$self->has_data ? 'yes' : 'no',
		-f $self->_generate_file_name ? 'yes' : 'no',
		$self->{file} ? 'yes' : 'no'
	);

	unlink $self->{file} if $self->{file} && -f $self->{file};
	$self->{data} = $self->{file} = undef;
	$self;
}

sub is_subset  {defined($_[0]->{subset})};

sub notify {
	$_[0]->{notice} = $_[1]//sprintf(
		"generating #c{%s} manifest...",
		$_[0]->label
	);
}

sub validate {
	my $self = shift;
	eval {
		my $type = $self->type;
		$self->builder->$type->data;
	};
	my $err = $@;
	error(
		"Failed to build %s manifest:\n\n%s",
		$self->label, fix_wrap($err)
	) if $err;
	return $err ? 0 : 1;
}

sub has_notice {defined($_[0]->{notice})}
sub get_build_notice {$_[0]->{notice}}


# Helper methods
sub _load_file { load_yaml_file($_[0]->file) }
sub _save_data_to_file {
	my ($self) = @_;
	my $file = $self->{file}//$self->_generate_file_name();
	save_to_yaml_file($self->{data},$file);
	$file;
}

sub _generate_file_name {
	my ($self) = @_;
	my $path = $self->env->workpath();
	my $type = $self->type;
	my $subset = $self->{subset} ? "-".$self->{subset} : '';
	sprintf(
		"%s/manifest-%s-%s-%s%s.yml",
		$path,
		$self->env->name,
		$self->env->signature,
		$type,
		$subset
	);
}

sub get_vault_paths {
	shift->builder->vault_paths(@_);
}

sub _merge {bug "Expected %s to define private _merge method", ref($_[0])}

sub _get_subset {
	my ($self, $req) = @_;
	return $self->builder->get_subset(
		$self, $self->{subset}, $req
	);
}

1;
