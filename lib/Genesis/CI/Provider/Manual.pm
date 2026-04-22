package Genesis::CI::Provider::Manual;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;

### Class Methods {{{

# init - create a Manual provider (no options needed) {{{
sub init {
	my ($class, %opts) = @_;
	$class->new(type => 'manual');
}

# }}}
# new - create a Manual provider {{{
sub new {
	my ($class, %config) = @_;
	bless({ label => 'Manual' }, $class);
}

# }}}
# opts_help - usage documentation for Manual provider {{{
sub opts_help {
	my ($class, %config) = @_;
	return '' unless grep { $_ eq 'manual' } @{$config{valid_types} || []};

	<<'EOF';
  CI Provider `manual`:

    This provider type disables automated pipeline management.  Genesis
    will scaffold the repository structure but no CI system will be
    automatically configured.  Use this when you manage your pipeline
    entirely outside of Genesis or through a separate process.

    No additional options are required.

EOF
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label { 'Manual' }

# }}}
# config - returns hash for .genesis/config ci.provider section {{{
sub config {
	my ($self) = @_;
	return (type => 'manual');
}

# }}}
# interactive_wizard - no prompts needed for Manual {{{
sub interactive_wizard {
	my ($self, $top) = @_;
	return $self->new(type => 'manual');
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Provider::Manual - Manual (no-automation) CI provider for Genesis repo-init

=head1 DESCRIPTION

A no-op CI provider for repositories that manage their pipelines manually.
Takes no additional options and stores only C<< type => 'manual' >> in config.

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
