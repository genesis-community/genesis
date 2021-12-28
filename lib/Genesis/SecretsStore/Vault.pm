package Genesis::SecretsStore::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::Vault;

use vars qw($AUTOLOAD);
sub AUTOLOAD {
	my $self = shift;

	# Never propagate DESTROY methods
	return if $AUTOLOAD =~ /::DESTROY$/;

	# Strip off its leading package name (such as Employee::)
	$AUTOLOAD =~ s/^.*:://;
	$self->{connection}->$AUTOLOAD(@_);
}

### Class Methods {{{

# new - crate a new Vault-based environment secrets store {{{
sub new {
	my ($class, %opts) = @_;

	# validate call
	my @required_options = qw/connection name type/;
	my @valid_options = (@required_options, qw/mount_override slug_override/);
	bug("No '$_' specified in call to Genesis::SecretsStore::Vault->new")
		for grep {!$opts{$_}} @required_options;
	bug("Unknown '$_' option specified in call to Genesis::SecretsStore::Vault->new")
		for grep {my $k = $_; ! grep {$_ eq $k} @valid_options} keys(%opts);

	return bless({%opts},$class);
}

# }}}
# }}}

### Instance Methods {{{

sub default_mount {
	'/secret/'
}
sub mount {
	my $self = shift;
	unless (defined($self->{mount})) {
		$self->{mount} = ($self->{mount_override} || $self->default_mount);
		$self->{mount} =~ s|^/?(.*?)/?$|/$1/|;
	}
	return $self->{mount};
}

sub default_slug {
	my $self = shift;
	(my $slug = $self->{name}) =~ s|-|/|g;
	$slug .= "/".$self->{type};
	return $slug
}

sub slug {
	my $self = shift;
	unless (defined($self->{slug})) {
		$self->{slug} = $self->{slug_override} || $self->default_slug;
		$self->{slug} =~ s|^/?(.*?)/?$|$1|;
	}
	return $self->{slug};
}

sub base {
	my $self = shift;
	$self->mount . $self->slug . '/';
}
#}}}
1;
