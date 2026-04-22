package Genesis::CI::Provider::Concourse;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;
use Genesis::UI;

use POSIX qw(mktime);

use constant {
	DEFAULT_TEAM => 'main',
};

### Class Methods {{{

# init - create a new Concourse provider from CLI options {{{
#
# Two modes:
#   1. Existing target: --ci-target <name> (looks up url/team/insecure
#      from ~/.flyrc)
#   2. New target: --ci-url <url> --ci-team <team> [--ci-insecure]
#      [--ci-target <name>]  (derives target name if not specified)
#
sub init {
	my ($class, %opts) = @_;

	my $has_target = $opts{'ci-target'};
	my $has_new    = $opts{'ci-url'} || $opts{'ci-team'} || $opts{'ci-insecure'};

	if ($has_target) {
		# Check if the target already exists in flyrc
		my $flyrc = "$ENV{HOME}/.flyrc";
		my $entry;
		if (-f $flyrc) {
			my $data = load_yaml_file($flyrc);
			$entry = $data->{targets}{$opts{'ci-target'}}
				if ref($data) eq 'HASH' && ref($data->{targets}) eq 'HASH';
		}

		if ($entry) {
			# Existing target — reject conflicting flags
			bail(
				"Target '%s' already exists in ~/.flyrc.\n".
				"  Cannot combine --ci-target with --ci-url, --ci-team, ".
				"or --ci-insecure when the target already exists.",
				$opts{'ci-target'}
			) if $has_new;

			return $class->new(
				type     => 'concourse',
				target   => $opts{'ci-target'},
				url      => $entry->{api},
				team     => $entry->{team} || DEFAULT_TEAM,
				insecure => $entry->{insecure} ? 1 : 0,
			);
		}

		# Target name provided but doesn't exist yet — fall through
		# to new-target creation below (--ci-url and --ci-team required)
	}

	# New target: --ci-url and --ci-team are required; --ci-target is
	# an optional name override (derived from url/team if omitted).
	bail(
		"Concourse CI provider requires --ci-target (existing fly target) ".
		"or --ci-url and --ci-team (new target)"
	) unless $opts{'ci-url'} && $opts{'ci-team'};

	my $target = $opts{'ci-target'}
		// _derive_target_name($opts{'ci-url'}, $opts{'ci-team'});

	return $class->new(
		type     => 'concourse',
		target   => $target,
		url      => $opts{'ci-url'},
		team     => $opts{'ci-team'},
		insecure => $opts{'ci-insecure'} ? 1 : 0,
	);
}

# }}}
# new - create a Concourse provider from stored config {{{
sub new {
	my ($class, %config) = @_;
	$class = ref($class) || $class;
	bless({
		label           => 'Concourse',
		target          => $config{target},
		url             => $config{url},
		team            => $config{team}            || DEFAULT_TEAM,
		insecure        => $config{insecure}        ? 1 : 0,
		min_fly_version => $config{min_fly_version} || undef,
	}, $class);
}

# }}}
# check_prereqs - verify fly CLI is present and meets min version {{{
sub check_prereqs {
	my ($self) = @_;

	my ($fly_path) = run({ stderr => 0 }, 'type -p fly');
	chomp($fly_path //= '');
	unless ($fly_path) {
		error(
			"Concourse CI provider requires the #C{fly} CLI but it was not found in PATH.\n".
			"  Download it from your Concourse server's home page or:\n".
			"    #C{<concourse-url>/api/v1/cli?arch=amd64&platform=<linux|darwin|windows>}"
		);
		return 0;
	}

	if ($self->{min_fly_version}) {
		my ($ver_out) = run({ stderr => 0 }, 'fly --version');
		chomp($ver_out //= '');
		if ($ver_out && $ver_out =~ /^(\d+)\.(\d+)\.(\d+)/) {
			my @got = ($1+0, $2+0, $3+0);
			my @min = map { $_ + 0 } split(/\./, $self->{min_fly_version}, 3);
			push @min, 0 while @min < 3;
			for my $i (0..2) {
				if ($got[$i] < ($min[$i]//0)) {
					error(
						"Concourse CI provider requires fly >= %s but found %s.\n".
						"  Upgrade fly from your Concourse server.",
						$self->{min_fly_version}, $ver_out
					);
					return 0;
				}
				last if $got[$i] > ($min[$i]//0);
			}
		}
	}

	return 1;
}

# }}}
# opts - Getopt::Long spec for Concourse-specific CLI flags {{{
sub opts {
	qw/
		ci-target=s
		ci-url=s
		ci-team=s
		ci-insecure
	/;
}

# }}}
# opts_help - usage documentation for Concourse options {{{
sub opts_help {
	my ($class, %config) = @_;
	return '' unless grep { $_ eq 'concourse' } @{$config{valid_types} || []};

	<<'EOF';
  CI Provider `concourse`:

    Use an existing fly target:

    --ci-target <name>
        An existing Concourse target name from ~/.flyrc.  URL, team, and
        TLS settings are read from the target.  Cannot be combined with
        --ci-url, --ci-team, or --ci-insecure when the target exists.

    Or specify a new target:

    --ci-url <url> (required for new targets)
        The Concourse server URL (e.g. https://ci.example.com).

    --ci-team <name> (required for new targets)
        The Concourse team name.

    --ci-target <name> (optional for new targets)
        Override the fly target name.  Defaults to a name derived from
        the URL and team (e.g. ci/platform).

    --ci-insecure (optional flag)
        Skip TLS certificate verification when connecting to the Concourse
        server.  Equivalent to fly's --skip-ssl-validation flag.

    When neither --ci-target nor --ci-url is provided, an interactive
    wizard guides target selection or creation.

EOF
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label { 'Concourse' }

# }}}
# validate_config - assert required fields are present in stored config {{{
sub validate_config {
	my ($self) = @_;
	my @errors;
	push @errors, "'target' is required for the Concourse provider"
		unless $self->{target};
	push @errors, "'url' must begin with http:// or https://"
		if $self->{url} && $self->{url} !~ m{^https?://};
	return @errors;
}

# }}}
# config - returns hash for .genesis/config ci.provider section {{{
sub config {
	my ($self) = @_;
	my %cfg = (type => 'concourse');
	$cfg{target}   = $self->{target}   if defined $self->{target};
	$cfg{url}      = $self->{url}      if defined $self->{url};
	$cfg{team}     = $self->{team}     if defined $self->{team} && $self->{team} ne DEFAULT_TEAM;
	$cfg{insecure} = 1                 if $self->{insecure};
	return %cfg;
}

# }}}
# interactive_wizard - select existing target or create a new one {{{
sub interactive_wizard {
	my ($self, $top) = @_;

	my ($target, $url, $team, $insecure);

	# --- Gather existing targets from fly targets + flyrc ---
	my @fly_targets = _load_fly_targets();

	if (@fly_targets) {
		# Compute column widths for aligned display
		my ($w_name, $w_api, $w_team) = (0, 0, 0);
		for (@fly_targets) {
			$w_name = length($_->{name}) if length($_->{name}) > $w_name;
			$w_api  = length($_->{api})  if length($_->{api})  > $w_api;
			$w_team = length($_->{team}) if length($_->{team}) > $w_team;
		}

		my @choices = map {{
			value   => $_->{name},
			label   => sprintf("#C{%-${w_name}s}  %-${w_api}s  %-${w_team}s  %s%s",
				$_->{name}, $_->{api}, $_->{team},
				$_->{insecure} ? "#Yi{insecure}" : "#G{secure}  ",
				$_->{expired}  ? "  #R{EXPIRED!}" : ""),
			summary => $_->{name},
		}} @fly_targets;

		push @choices, { separator => 1 };
		push @choices, {
			value   => '__new__',
			label   => '#Yi{Create a new Concourse target}',
			summary => '(new target)',
		};

		my $selection = new_prompt_for_choice(
			header      => "Select a Concourse target:",
			choices     => \@choices,
			default     => $self->{target},
			description => "target",
		);

		if ($selection ne '__new__') {
			my ($selected) = grep { $_->{name} eq $selection } @fly_targets;
			$target   = $selected->{name};
			$url      = $selected->{api};
			$team     = $selected->{team};
			$insecure = $selected->{insecure};

			# Re-authenticate if the token has expired
			if ($selected->{expired}) {
				info "\nRe-authenticating expired target #C{%s}...\n", $target;
				my @cmd = ('fly', '-t', $target, 'login', '-n', $team);
				push @cmd, '-k' if $insecure;
				run({ interactive => 1,
					  onfailure   => "fly login failed for target '$target'" },
					@cmd);
			}
		}
	}

	# Create a new target: prompt for details and run fly login
	unless ($target) {
		$url = prompt_for_line(undef,
			"Concourse URL (e.g. https://ci.example.com): ", '');
		bail("A Concourse URL is required.") unless $url && $url =~ m{^https?://};

		$team = prompt_for_line(undef,
			sprintf("Team name [%s]: ", DEFAULT_TEAM), DEFAULT_TEAM);
		$team = DEFAULT_TEAM unless $team && $team =~ /\S/;

		$insecure = prompt_for_boolean(
			"Skip TLS certificate verification? [y|n] ", 0);

		$target = _derive_target_name($url, $team);

		info "\nLogging in to #C{%s} as team #C{%s} (target: #C{%s})...\n",
			$url, $team, $target;
		my @cmd = ('fly', '-t', $target, 'login',
			'-c', $url, '-n', $team);
		push @cmd, '-k' if $insecure;
		run({ interactive => 1,
			  onfailure   => "fly login failed for target '$target'" },
			@cmd);
	}

	return $self->new(
		type     => 'concourse',
		target   => $target,
		url      => $url,
		team     => $team,
		insecure => $insecure ? 1 : 0,
	);
}

# }}}

# _load_fly_targets - merge fly targets output with flyrc insecure flags {{{
sub _load_fly_targets {
	my @targets;

	my $flyrc = "$ENV{HOME}/.flyrc";
	my %flyrc_data;
	if (-f $flyrc) {
		my $data = load_yaml_file($flyrc);
		if (ref($data) eq 'HASH' && ref($data->{targets}) eq 'HASH') {
			%flyrc_data = %{$data->{targets}};
		}
	}

	my ($fly_out) = run({ stderr => '/dev/null' },
		'fly targets --print-table-headers');
	if ($fly_out && $fly_out =~ /\S/) {
		my @lines = split /\n/, $fly_out;
		my @rows = parse_fixed_width_table(@lines);
		for my $row (@rows) {
			my $name = $row->{name} // next;
			my $flyrc_entry = $flyrc_data{$name} // {};
			push @targets, {
				name     => $name,
				api      => $row->{url}  // '(unknown)',
				team     => $row->{team} // DEFAULT_TEAM,
				insecure => $flyrc_entry->{insecure} ? 1 : 0,
				expired  => _token_expired($row->{expiry}),
			};
		}
	}
	return @targets;
}

# }}}
# _derive_target_name - build a target name from url and team {{{
sub _derive_target_name {
	my ($url, $team) = @_;
	# https://ci.example.com → ci
	# https://pipes.scalecf.net → pipes
	(my $host = $url) =~ s{^https?://}{}; $host =~ s{[:/].*}{};
	my $subdomain = (split /\./, $host)[0] // $host;
	return $team eq 'main' ? $subdomain : "$subdomain/$team";
}

# }}}
# _token_expired - check if a fly targets expiry string is in the past {{{
my %_months = (
	Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4,  Jun => 5,
	Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11,
);
sub _token_expired {
	my ($expiry_str) = @_;
	return 0 unless $expiry_str && $expiry_str =~ /\S/;

	# fly targets format: "Sat, 08 Feb 2025 18:53:16 UTC"
	if ($expiry_str =~ /(\d{2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+UTC/) {
		my ($day, $mon, $year, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
		return 0 unless defined $_months{$mon};
		my $exp = eval {
			local $ENV{TZ} = 'UTC';
			POSIX::mktime($sec, $min, $hour, $day, $_months{$mon}, $year - 1900);
		};
		return 0 unless $exp;
		return $exp < time() ? 1 : 0;
	}
	return 0;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Provider::Concourse - Concourse CI provider for Genesis repo-init

=head1 DESCRIPTION

Manages Concourse-specific CI configuration in .genesis/config ci.provider.

=head1 SYNOPSIS

  my $p = Genesis::CI::Provider::Concourse->init(
    'ci-target'   => 'prod',
    'ci-team'     => 'platform',
    'ci-insecure' => 0,
  );
  my %cfg = $p->config;
  # { type => 'concourse', target => 'prod', team => 'platform' }

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
