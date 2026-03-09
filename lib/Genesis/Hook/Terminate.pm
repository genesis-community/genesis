package Genesis::Hook::Terminate v3.2.0;
use strict;
use warnings;
use 5.20.0;

use parent qw(Genesis::Hook);

use Genesis;
use Genesis::UI qw/prompt_for_boolean/;
use Genesis::Term qw/bullet/;

# Hook initialization
sub init {
	my ($class, %args) = @_;
	# If dry_run was passed in, it should be renamed to dryrun
	$args{dryrun} = delete $args{dry_run} if exists $args{dry_run};
	$class->check_for_required_args({%args}, qw/env kit mode dryrun force noprompt/);
	my $obj = $class->SUPER::init(%args);
	
	# Validate the mode
	bug(
		"Unknown termination mode '%s'; expected 'before', 'after', or 'failed'",
		$obj->{mode}
	) unless $obj->{mode} =~ /^(before|after|failed)$/;
	$obj->{complete} = 0;
	return $obj;
}

sub perform {
	# Default perform method for terminate -- override in subclass if alternative behavior is needed
	my ($self) = @_;

	# Build the method referrence from the mode - we don't have to
	# validate the mode here because it was already done in init
	my $method = $self->{mode}."_terminate";

	$self->kit->kit_bug(
		"The #B{%s} method for the terminate hook in #M{%s} is not implemented",
		$method,
		$self->kit->name
	) unless $self->can($method);

	# Call the method
	my $result = $self->$method(@_);

	return $self->done($result);
}

sub is_dryrun {
	return $_[0]->{dryrun};
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
