package Genesis::Commands::Deprecated;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;

sub redirect {
	prepare_command(command_properties->{deprecated}, @_);
	::check_prereqs() unless command_properties->{skip_check_prereqs};
	run_command;
};

1;
