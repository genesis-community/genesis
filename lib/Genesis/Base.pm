package Genesis::Base;

use strict;
use warnings;
use utf8;
use Genesis;
use Time::HiRes qw/gettimeofday/;

# _memoize - cache value to be returned on subsequent calls {{{
sub _memoize {
	my ($self, $token, $initialize) = @_;
	if (ref($token) eq 'CODE') {
		$initialize = $token;
		$token = $self->_get_token();
	}
	if (defined($self->{$token})) {
		# If the value is already set, return it
		trace("using memoized value for %s", $token);
		return $self->{$token};
	}

	trace("memoizing value for %s", $token);
	my $start = gettimeofday();
	$self->{$token} = $initialize->($self);
	trace(
		"memoized value for %s in %.3f seconds",
		$token, gettimeofday() - $start
	);
	return $self->{$token};
}

sub _set_memo {
	my ($self, $token, $value) = @_;
	if (!defined($value)) {
		$value = $token;
		$token = $self->_get_token();
	}
	return $self->{$token} = $value;
}

sub _clear_memo {
	my ($self, $token) = @_;
	$token ||= $self->_get_token();
	my $last = $self->{$token};
	$self->{$token} = undef;
	return $last;
}

sub _get_memo {
	my ($self, $token) = @_;
	$token ||= $self->_get_token();
	return $self->{$token};
}

sub _get_token {
	my ($self, $level) = @_;
	$level = 1 unless defined($level);
	my $caller;
	while ($caller = (caller($level))[3]) {
		$level++;
		my ($pkg,$sub) = $caller =~ m/^(.*)::([^:]*)$/;
		next unless $pkg && $pkg eq ref($self);
		next if !defined($sub) || $sub =~ /^__ANON__$/;
		return "__$sub";
	}
	bug("Could not find %s in stack; cannot determine memoization token", ref($self));
}

sub _get_token_for {
	my ($self, $method) = @_;
	my ($pkg,$sub) = $method =~ m/^(?:(.*)::)?([^:]*)$/;
	return unless ($pkg || ref($self))->can($method);
	return if $sub =~ /^__ANON__$/;
	return "__$sub";
}

1;
