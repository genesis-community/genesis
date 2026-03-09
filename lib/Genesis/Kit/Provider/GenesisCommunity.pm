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
	my ($class) = @_;
	my $label = "Genesis Community organization on Github";
	bless({
		label  => $label,
		remote => Service::Github->new(
								domain => "github.com",
								org    => "genesis-community",
								tls    => "yes",
								label  => $label
							)
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
		"Source"   => $self->label,
		status    => $info{status},
		kits      => $info{kits}
	};
	return %$new_info;
}

# }}}

# Rest inherited from Genesis::Kit::Provider::Github

# }}}
1;

# vim: fdm=marker:foldlevel=1:noet
