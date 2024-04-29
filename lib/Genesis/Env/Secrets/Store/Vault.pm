package Genesis::Env::Secrets::Store::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::Term;

use vars qw($AUTOLOAD);
sub AUTOLOAD {
	my $self = shift;

	# Never propagate DESTROY methods
	return if $AUTOLOAD =~ /::DESTROY$/;

	# Strip off its leading package name (such as Employee::)
	$AUTOLOAD =~ s/^.*:://;
	$self->{service}->$AUTOLOAD(@_);
}

### Class Methods {{{

# new - crate a new Vault-based environment secrets store {{{
sub new {
	my ($class, $env, %opts) = @_;

	# validate call
	my @required_options = qw/service/;
	my @valid_options = (@required_options, qw/mount_override slug_override root_ca_override/);
	bug("No '$_' specified in call to Genesis::Env::SecretsStore::Vault->new")
		for grep {!$opts{$_}} @required_options;
	bug("Unknown '$_' option specified in call to Genesis::Env::SecretsStore::Vault->new")
		for grep {my $k = $_; ! grep {$_ eq $k} @valid_options} CORE::keys(%opts);

	$opts{mount_override}   //= $env->lookup('genesis.secrets_mount');
	$opts{slug_override}    //= $env->lookup(['genesis.secrets_path','params.vault_prefix','params.vault']);
	$opts{root_ca_override} //= $env->lookup('genesis.root_ca_path','') =~ s/\/$//r;

	return bless({
			env => $env,
			%opts
		},$class
	);
}

# }}}
# }}}

### Instance Methods {{{

sub env {$_[0]->{env}}
sub service {$_[0]->{service}}

sub default_mount {
	'/secret/'
}
sub mount {
	my $self = shift;
	unless (defined($self->{__mount})) {
		$self->{__mount} = ($self->{mount_override} || $self->default_mount);
		$self->{__mount} =~ s|^/?(.*?)/?$|/$1/|;
	}
	return $self->{__mount};
}

sub default_slug {
	my $self = shift;
	(my $slug = $self->env->name) =~ s|-|/|g;
	$slug .= "/".$self->env->type;
	return $slug
}

sub slug {
	my $self = shift;
	unless (defined($self->{__slug})) {
		$self->{__slug} = $self->{slug_override} || $self->default_slug;
		$self->{__slug} =~ s|^/?(.*?)/?$|$1|;
	}
	return $self->{__slug};
}

sub base {
	my $self = shift;
	$self->mount . $self->slug . '/';
}

sub path {
	($_[0]->base().($_[1]||'')) =~ s/\/$//r;
}

# root_ca_path - returns the root_ca_path, if provided by the environment file (env: GENESIS_ROOT_CA_PATH) {{{
sub root_ca_path {
	my $self = shift;
	unless (exists($self->{__root_ca_path})) {
		$self->{__root_ca_path} = $self->{root_ca_override} || $ENV{GENESIS_ROOT_CA_PATH} || '';
		$self->{__root_ca_path} =~ s|^/?(.*?)/?$|/$1| if $self->{__root_ca_path};
	}

	return $self->{__root_ca_path};
}

sub store_data {
	my $self = shift;
	$self->{__data} //= read_json_from($self->service->query('export', grep {$_} ($self->base, $self->root_ca_path)));
	return $self->{__data}//{};
}

sub store_paths {
	return CORE::keys %{$_[0]->store_data};
}

sub clear_data {
	delete($_[0]->{__data})
}

sub paths {
	my $self = shift;
	return $self->service->paths(@_) unless exists($self->{__data});
	my @paths = ();
	my $base = $self->base =~ s/^\///r;
	for my $path (@_) {
		if ($path =~ /^$base/) {
			my $spath = $path =~ s/\/$//r;
			my @sub_paths = grep {$_ =~ /^\/$spath(\/|$)/} CORE::keys %{$self->{__data}};
			push(@paths, @sub_paths);
		} else {
			#use Pry; pry();
			# if its not under the store base, then its not in the store
			push(@paths, $self->service->paths($path));
		}
	}
	return @paths;
}

sub keys {
	my $self = shift;
	return $self->service->keys(@_) unless exists($self->{__data});
	my @paths = $self->paths(@_);
	my @keys = ();
	for my $path (@paths) {
		my $base = $self->base;
		if ($path =~ /^$base\//) {
			push (@keys, CORE::keys %{$self->{__data}{$path}})
		} else {
			push (@keys, $self->service->keys($path));
		}
	}
	return @keys;
}

# }}}

sub exists {
	my ($self, $secret) = @_;
	my ($path,$key) = split /:/, $secret->full_path, 2;
	$key = $secret->default_key unless defined($key);
	return $self->service->has($path, $key);
}

sub read   {
	my ($self, $secret) = @_;
	my $path = $secret->path;
	$path .= ":".$secret->default_key if $secret->default_key;
	my $value = $self->service->has($self->path($path)) 
		? $self->service->get($self->path($path))
		: undef;
	$secret->set_value($value, loaded => 1);

	if ($secret->can('format_path') && (my $format_path = $secret->format_path)) {
		my $format_path = $secret->format_path;
		my $fmt_value = $self->service->has($self->path($format_path))
			? $self->service->get($self->path($format_path))
			: undef;
		$secret->set_format_value($fmt_value);
	}
	$secret->promote_value_to_stored();
	return $secret;
}

sub write   {
	my ($self, $secret) = @_;
	my @results = ();
	if ($secret->path =~ ':') {
		$self->service->set(split(":",$self->path($secret->path),2), $secret->value);
		if ($secret->can('format_path') && (my $format_path = $secret->format_path)) {
			$self->service->set($self->path($format_path), $_, $secret->calc_format_value);
		}
	} elsif (ref($secret->value) eq 'HASH') {
		my %values = %{$secret->value};
		for my $key ( map {(split ':', $_, 2 )[1]} $self->service->keys($self->path($secret->path))) {
			next if exists($secret->value->{$key});
			$self->service->query('rm', join(":", ($self->path($secret->path),$_)));
		}	;
		$self->service->set($self->path($secret->path), $_, $values{$_}) for CORE::keys %values;
	} else {
		my $key = $secret->default_key//'value';
		$self->service->set($self->path($secret->path), $key, $secret->value);
	}
	$secret->promote_value_to_stored();

	delete($self->{__data});
	return $secret;
}

sub fill  {
	my ($self, @secrets) = @_;
	my $data = $self->store_data();
	my $pause = 0;
	for my $secret (@secrets) {
		my $path = $self->path($secret->path) =~ s#/?(.*?)/?#$1#r;
		my $key = $secret->default_key;
		($path,$key) = split(":",$path,2) if $path =~ /:/;
		next unless defined($data->{$path});
		if (defined($key)) {
			$secret->set_value($data->{$path}{$key});
			if ($secret->can('format_path') && (my $format_path = $secret->format_path)) {
				my ($_path, $_key) = split(":", $self->path($format_path) =~ s/^\///r, 2);
				$secret->set_format_value($data->{$_path}{$_key})
			}
			$secret->promote_value_to_stored;
		} else {
			$secret->set_value($data->{$path}, in_sync => 1)
		}
	}
	return;
}

sub check {
	my ($self, $secret) = @_;
	my $ok = $self->get($secret) unless $secret->has_value;
	return $ok;
}

sub validate {
	my ($self, $secret) = @_;
	my $ok = $self->get($secret) unless $secret->has_value;
	return $secret->validate();
}

sub generate {
	my ($self, $secret) = @_;
	bail "Generate not implemented for Vault store";
}

sub regenerate {
	bail "Regenerate not implemented for Vault store";}

sub remove {
	bail "Remove not implemented for Vault store";
}

sub remove_all {
	bail "Remove_all not implemented for Vault store";
}

1;
