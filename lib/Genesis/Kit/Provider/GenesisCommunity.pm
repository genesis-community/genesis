package Genesis::Kit::Provider::GenesisCommunity;
use strict;
use warnings;

use base 'Genesis::Kit::Provider::Github';
use Genesis;
use Genesis::Helpers;

### Class Methods {{{

# init - creates a new provider on repo init or change {{{
sub init {
	$_[0]->new();
}

# }}}
# new - create a default genesis-community kit provider {{{
sub new {
	my ($class, %config) = @_;
	my $credentials;
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$credentials = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	}
	bless({
		domain        => "github.com",
		organization  => "genesis-community",
		credentials   => $credentials,
		label         => "Genesis Community organization on Github",
		tls           => "yes"
	}, $class);
}

# }}}
# opts -  list of options supported by init method {{{
sub opts {
	qw//;
}

# }}}
# opts_help - specifies the new/update options understood by this provider {{{
sub opts_help {
	my ($self,%config) = @_;
	return '' unless grep {$_ eq 'genesis-community'} (@{$config{valid_types}});

	<<EOF
  Kit Provider `genesis-community`:

    This is a singleton kit provider type that points to the Genesis Community
    collection of kits hosted on github.com/genesis-community - it is the
    default provider type and doesn't take any further options.

EOF
}
# }}}

### Instance Methods {{{

# config - provides the config hash used to specify this provider {{{
sub config {
	my ($self) = @_;
	my $config = {
		type         => 'genesis-community',
	};
	return %$config;
}
# }}}
# status - The human-understandable label for messages and errors {{{
sub status {
	my ($self,$verbose) = @_;
	my %info = $self->SUPER::status($verbose);

	my $new_info = {
		type      => 'genesis-community',
		extras     => ["Source"],
		"Source"   => $self->{label},
		status    => $info{status},
		kits      => $info{kits}
	};
	return %$new_info;
}

# }}}

# Rest inherited from Genesis::Kit::Provider::Github

# }}}
1;

=head1 NAME

Genesis::Kit::Provider::Default

=head1 DESCRIPTION

This class represents a compiled kit, and its distribution as a tarball
archive.  Most operators use kits in this format.

=head1 CONSTRUCTORS

=head2 new(%opts)

Instantiates a new Kit::Compiled object.

The following options are recognized:

=over

=item name

The name of the kit.  This option is B<required>.

=item version

The version of the kit.  This option is B<required>.

=item archive

The absolute path to the compiled kit tarball.  This option is B<required>.

=back


=head1 METHODS

=head2 id()

Returns the identity of the kit, in the form C<$name/$verison>.  This is
useful for error messages and reporting.

=head2 name()

Returns the name of the kit.

=head2 version()

Returns the version of the kit.

=head2 kit_bug($fmt, ...)

Prints an error to the screen, complete with details about how the problem
at hand is not the operator's fault, and that they should file a bug against
the kit's Github page, or contact the authors.

=head2 extract()

Extracts the compiled kit tarball to a temporary workspace, and installs the
Genesis hooks helper script.

This method is memoized; subsequent calls to C<extract> will have no effect.

=cut
# vim: fdm=marker:foldlevel=1:noet
