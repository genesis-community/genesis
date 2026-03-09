package Genesis::Commands::Ocfp;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;

# ocfp - Top-level OCFP command dispatch {{{
sub ocfp {
	my %options = %{get_options()};
	my ($env_name, $topic, $action, @extra_args) = @_;

	command_usage(1, "Environment name, topic, and action are required")
		unless $env_name && $topic && $action;

	bail("Too many arguments provided") if @extra_args > 0;

	my @valid_topics = qw(show);
	bail(
		"Invalid topic: '%s' - expected one of: %s",
		$topic, sentence_join(@valid_topics)
	) unless grep {$_ eq $topic} @valid_topics;

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault();

	bail(
		"Environment '%s' is not an OCFP environment.\n".
		"The 'ocfp' command requires an environment with the 'ocfp' feature enabled.",
		$env->name
	) unless $env->is_ocfp;

	if ($topic eq 'show') {
		return ocfp_show($env, $action, %options);
	}
}

# }}}
# ocfp_show - Dispatch 'show' topic actions {{{
sub ocfp_show {
	my ($env, $action, %options) = @_;

	my @valid_actions = qw(network);
	bail(
		"Invalid show action: '%s' - expected one of: %s",
		$action, sentence_join(@valid_actions)
	) unless grep {$_ eq $action} @valid_actions;

	if ($action eq 'network') {
		require Genesis::Commands::Ocfp::ShowNetwork;
		return Genesis::Commands::Ocfp::ShowNetwork::run($env, %options);
	}
}

# }}}

1;
