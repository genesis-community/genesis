package Genesis::Vault;
use strict;
use warnings;

use Genesis::Utils;

sub target {
	my ($class, $target) = @_;
	return bless({ target => $target }, $class);
}

sub select {
	my ($class) = @_;
	run({ interactive => 1, onfailure => "Unable to set your Vault target via safe" },
		'safe', 'target', '-i');

	# FIXME: once we min-require safe 0.7.0, use `targets --json` instead
	my $target = run({ onfailure => "Unable to determine the targeted Vault" },
		'safe target 2>&1 | grep "$1" | sed -e "$2"',
		'.*targeting .* at.*', 's/.*targeting \([^ ]*\) at.*/\1/'

	return $class->target($target);
}

sub has {
	my ($self, $path) = @_;
	return run({ passfail => 1 }, 'safe', '-T', $self->{target}, 'exists', $path);
}

sub ping {
	my ($self) = @_;
	return $self->has('secret/handshake');
}

1;
