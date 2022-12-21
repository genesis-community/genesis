package Genesis::CI::Legacy;
use strict;
use warnings;

use Genesis;
use Genesis::Top;
use Genesis::UI;
use Socket qw/inet_ntoa/;
use JSON::PP;

sub string_to_yaml {
	# Note: the resulting string MUST be surrounded by double quotes
	if (ref($_[0])) {
		return JSON::PP->new->encode($_[0]);
	} else {
		return substr(JSON::PP->new->allow_nonref->encode($_[0]), 1, -1);
	}
}
sub boolean_to_yaml {
	return $_[0] ? "true" : "false";
}
sub yaml_bool {
	my ($bool, $default) = @_;
	return ($default || 0) unless defined($bool);
	return $bool;
}

# FYI: we use quasi-JSON here, so we don't need to care about our indent level when consuming
#      the notification definitions
sub _gen_notifications {
	my ($pipeline, $message, $alias) = @_;
	$alias = "" unless defined $alias;
	my $notification = "in_parallel: [\n";
	my $pipeline_name = $pipeline->{pipeline}{name};
	my $message_as_yaml = string_to_yaml($message);
	if ($pipeline->{pipeline}{slack}) {
		$notification .= <<EOF;
{
  put: "slack",
  params: {
    channel:  (( grab pipeline.slack.channel )),
    username: (( grab pipeline.slack.username )),
    icon_url: (( grab pipeline.slack.icon )),
    text:     "$pipeline_name: $message_as_yaml"
  }
},
EOF
	}
	if ($pipeline->{pipeline}{hipchat}) {
		$notification .= <<EOF;
{
  put: "hipchat",
  params: {
    from:     (( grab pipeline.hipchat.username )),
    color:   "gray",
    message: "$pipeline_name: $message_as_yaml",
    notify:  (( grab pipeline.hipchat.notify ))
  }
},
EOF
	}
	if ($pipeline->{pipeline}{stride}) {
		$notification .= <<EOF;
{
  put: "stride",
  params: {
    conversation: (( grab pipeline.stride.conversation )),
    message:      "$pipeline_name: $message_as_yaml"
  }
},
EOF
	}
	if ($pipeline->{pipeline}{email}) {
		my ($registry_prefix, $registry_creds) = ("", "");
		if ($pipeline->{pipeline}{registry}{uri}) {
			$registry_prefix = $pipeline->{pipeline}{registry}{uri} . "/";
			if ($pipeline->{pipeline}{registry}{username}) {
				my $registry_password_as_yaml = string_to_yaml($pipeline->{pipeline}{registry}{password});
				$registry_creds = <<EOF
          username: $pipeline->{pipeline}{registry}{username},
          password: "$registry_password_as_yaml",
EOF
			}
		}
		$notification .= <<EOF;
{
  do: [
  { task: write-email-body,
    params: {
      PIPELINE_NAME: (( grab pipeline.name ))
    },
    config: {
      platform: linux,
      image_resource: {
        type: registry-image,
        source: {
${registry_creds}
          repository: ${registry_prefix}$pipeline->{pipeline}{task}{image},
          tag:        $pipeline->{pipeline}{task}{version}
        },
      },
      outputs: [
        { name: email },
      ],
      run: {
        path: bash,
        args: [
          "-exc",
          "mkdir -p email ; rm -rf email/* ; echo \\\"\${PIPELINE_NAME}\\\" > email/subject ; echo \\\"${message_as_yaml}\\\" > email/body",
        ],
      },
    },
  },

  { put: email,
    params: {
      subject: email/subject,
      body:    email/body,
    },
  }]
}
EOF
	}
	$notification .= "]";
	return $notification;
}

sub parse_pipeline {
	my ($file, $top) = @_;

	my @errors = ();
	my $p = load_yaml(run({ onfailure => "Failed to evaluate pipeline $file", stderr => 0}, 'spruce', 'merge', $file));
	unless (exists $p->{pipeline}) {
		# fatal error
		push @errors, "Missing top-level 'pipeline:' key.";
		return $p, \@errors;
	}

	unless (ref($p->{pipeline}) eq 'HASH') {
		# fatal error
		push @errors, "Top-level 'pipeline:' key must be a map.";
		return $p, \@errors;
	}
	for (keys %{$p->{pipeline}}) {
		push @errors, "Unrecognized `pipeline.$_' key found."
			unless m/^(name|public|tagged|errands|ocfp|vault|git|slack|hipchat|stride|email|boshes|task|layout|layouts|groups|debug|locker|unredacted|notifications|auto-update|registry)$/;
	}
	for (qw(name vault git boshes)) {
		push @errors, "`pipeline.$_' is required."
			unless $p->{pipeline}{$_};
	}

	# validate pipeline.vault.*
	if (ref($p->{pipeline}{vault}) ne 'HASH') {
		push @errors, "`pipeline.vault' must be a map.";
	} else {
		# required subkeys
		for (qw(url)) {
			push @errors, "`pipeline.vault.$_' is required."
				unless $p->{pipeline}{vault}{$_};
		}
		# allowed subkeys
		for (keys %{$p->{pipeline}{vault}}) {
			push @errors, "Unrecognized `pipeline.vault.$_' key found."
				unless m/^(url|role|secret|verify|no-strongbox|namespace)$/;
		}
	}

	# validate pipeline.git.*
	if (ref($p->{pipeline}{git}) ne 'HASH') {
		push @errors, "`pipeline.git' must be a map.";
	} else {
		# Git can either use ssh keys or username/password
		if ($p->{pipeline}{git}{private_key}) {
			if ($p->{pipeline}{git}{username} || $p->{pipeline}{git}{password}) {
				push @errors, "'pipeline.git' cannot specify both 'private_key' and 'username/password'.";
			} elsif ($p->{pipeline}{git}{uri}) {
				for (qw(host owner repo)) {
					push @errors, "Cannot specify 'pipeline.git.$_' key if specifying 'pipeline.git.url'."
						if $p->{pipeline}{git}{$_};
				}
			} else {
				push @errors, "Must specify either 'uri', or 'owner' and 'repo' under 'pipeline.git'."
					unless ($p->{pipeline}{git}{owner} && $p->{pipeline}{git}{repo});
				$p->{pipeline}{git}{uri} = sprintf("git@%s:%s/%s",
					($p->{pipeline}{git}{host} || 'github.com'),
					$p->{pipeline}{git}{owner}, $p->{pipeline}{git}{repo});
			}
		} elsif ($p->{pipeline}{git}{username} || $p->{pipeline}{git}{password}) {
			if ($p->{pipeline}{git}{uri}) {
				for (qw(host owner repo)) {
					push @errors, "Cannot specify 'pipeline.git.$_' key if specifying 'pipeline.git.url'."
					if $p->{pipeline}{git}{$_};
				}
			} else {
				push @errors, "Must specify either 'uri', or 'owner' and 'repo' under 'pipeline.git'."
				unless ($p->{pipeline}{git}{owner} && $p->{pipeline}{git}{repo});
				$p->{pipeline}{git}{uri} = sprintf("https://%s/%s/%s.git",
					($p->{pipeline}{git}{host} || 'github.com'),
					$p->{pipeline}{git}{owner}, $p->{pipeline}{git}{repo});
			}
		} else {
			push @errors, "'pipeline.git' must specify either 'private_key', or  'username' and 'password'.";
		}
		$p->{pipeline}{git}{commits} = {} unless (exists $p->{pipeline}{git}{commits});
		if (ref($p->{pipeline}{git}{commits}) ne "HASH") {
			push @errors, "'pipeline.git.commits' must be a map.";
		} else {
			# allowed subkeys
			for (keys %{$p->{pipeline}{git}{commits}}) {
				push @errors, "Unrecognized `pipeline.git.commits.$_' key found."
					unless m/^(user_name|user_email)$/;
			}
			$p->{pipeline}{git}{commits}{user_name} ||= 'Concourse Bot';
			$p->{pipeline}{git}{commits}{user_email} ||= 'concourse@pipeline';
		}
		($p->{pipeline}{git}{root} ||= '.') =~ s#/*$##;
	}

	# validate locker
	if ($p->{pipeline}{locker}) {
		if (ref($p->{pipeline}{locker}) ne 'HASH') {
			push @errors, "`pipeline.locker' must be a map.";
		} else {
			for (qw/url username password/) {
				push @errors, "`pipeline.locker.$_' is required."
					unless $p->{pipeline}{locker}{$_};
			}
			for (keys %{$p->{pipeline}{locker}}) {
				push @errors, "Unrecognized `pipeline.locker.$_' key found."
					unless m/^(url|username|password|ca_cert|skip_ssl_validation)/;
			}
		}
	} else {
		$p->{pipeline}{locker}{url} = "";
	}

	# validate notifications
	my $n = 0;
	for (qw(slack hipchat stride email)) {
		$n++ if exists $p->{pipeline}{$_};
	}
	if ($n == 0) {
		push @errors, "No notification stanzas defined.  Please define `pipeline.slack', `pipeline.hipchat', `pipeline.stride' or `pipeline.email'.\n";
	} else {
		if ($p->{pipeline}{slack}) {
			# validate pipeline.slack.*
			if (ref($p->{pipeline}{slack}) ne 'HASH') {
				push @errors, "`pipeline.slack' must be a map.";
			} else {
				# required subkeys
				for (qw(webhook channel)) {
					push @errors, "`pipeline.slack.$_' is required."
						unless $p->{pipeline}{slack}{$_};
				}
				# allowed subkeys
				for (keys %{$p->{pipeline}{slack}}) {
					push @errors, "Unrecognized `pipeline.slack.$_' key found."
						unless m/^(webhook|channel|username|icon)$/;
				}
			}
		}
		if ($p->{pipeline}{hipchat}) {
			# validate pipeline.hipchat.*
			if (ref($p->{pipeline}{hipchat}) ne 'HASH') {
				push @errors, "`pipeline.hipchat' must be a map.";
			} else {
				# required subkeys
				for (qw/room_id token/) {
					push @errors, "`pipeline.hipchat.$_' is required."
						unless $p->{pipeline}{hipchat}{$_};
				}
				# allowed subkeys
				for (keys %{$p->{pipeline}{hipchat}}) {
					push @errors, "Unrecognized `pipeline.hipchat.$_' key found."
						unless m/^(url|token|room_id|notify|username)$/;
				}
			}
		}
		if ($p->{pipeline}{stride}) {
			# validate pipeline.stride.*
			if (ref($p->{pipeline}{stride}) ne 'HASH') {
				push @errors, "`pipeline.stride' must be a map.";
			} else {
				# required subkeys
				for (qw/client_id client_secret cloud_id conversation/) {
					push @errors, "`pipeline.stride.$_' is required."
						unless $p->{pipeline}{stride}{$_};
				}
				# allowed subkeys
				for (keys %{$p->{pipeline}{stride}}) {
					push @errors, "Unrecognized `pipeline.stride.$_' key found."
						unless m/^(client_id|client_secret|cloud_id|conversation)$/;
				}
			}
		}
		if ($p->{pipeline}{email}) {
			# validate pipeline.email.*
			if (ref($p->{pipeline}{email}) ne 'HASH') {
				push @errors, "`pipeline.email' must be a map.";
			} else {
				# required subkeys
				for (qw(to from smtp)) {
					push @errors, "`pipeline.email.$_' is required."
						unless $p->{pipeline}{email}{$_};
				}
				# to must be a list...
				if (exists $p->{pipeline}{email}{to}) {
					if (ref($p->{pipeline}{email}{to}) ne 'ARRAY') {
						push @errors, "`pipeline.email.to' must be a list of addresses.";
					} else {
						if (@{$p->{pipeline}{email}{to}} == 0) {
							push @errors, "`pipeline.email.to' must contain at least one address.";
						}
					}
				}
				# allowed subkeys
				for (keys %{$p->{pipeline}{email}}) {
					push @errors, "Unrecognized `pipeline.email.$_' key found."
						unless m/^(to|from|smtp)$/;
				}
				if (ref($p->{pipeline}{email}{smtp}) eq 'HASH') {
					# required sub-subkeys
					for (qw(host username password)) {
						push @errors, "`pipeline.email.smtp.$_' is required."
							unless $p->{pipeline}{email}{smtp}{$_};
					}
					# allowed subkeys
					for (keys %{$p->{pipeline}{email}{smtp}}) {
						push @errors, "Unrecognized `pipeline.email.smtp.$_' key found."
							unless m/^(host|port|username|password)$/;
					}
				} else {
				}
			}
		}
	}

	# validate (optional) pipeline.registry.*
	if (exists $p->{pipeline}{registry}) {
		if (ref($p->{pipeline}{registry}) ne 'HASH') {
			push @errors, "`pipeline.registry' must be a map.";
		} else {
			# allowed subkeys
			for (keys %{$p->{pipeline}{registry}}) {
				push @errors, "Unrecognized `pipeline.registry.$_' key found."
					unless m/^(uri|username|password)$/;
			}
		}
	}

	# validate (optional) pipeline.task.*
	if (exists $p->{pipeline}{task}) {
		if (ref($p->{pipeline}{task}) ne 'HASH') {
			push @errors, "`pipeline.task' must be a map.";
		} else {
			# allowed subkeys
			for (keys %{$p->{pipeline}{task}}) {
				push @errors, "Unrecognized `pipeline.task.$_' key found."
					unless m/^(image|version|privileged)$/;
			}
			if (exists($p->{pipeline}{task}{privileged}) && ref($p->{pipeline}{task}{privileged}) ne "ARRAY") {
				push @errors, "`pipeline.task.privileged` must be an array.";
			}
		}
	}

	# validate (optional) pipeline.notifications
	if (exists $p->{pipeline}{notifications}) {
		if (ref($p->{pipeline}{notifications}) || $p->{pipeline}{notifications} !~ /^(inline|parallel|grouped)$/) {
			push @errors, "pipeline.notifications must be one of parallel, grouped or inline (default)";
		}
	}

	# validate layouts
	my $key = undef; # for better messaging, later
	if (exists $p->{pipeline}{layout} && exists $p->{pipeline}{layouts}) {
		push @errors, "Both `pipeline.layout' and `pipeline.layouts' (plural) specified.  Please pick one or the other.";
	} elsif (exists $p->{pipeline}{layout}) {
		$p->{pipeline}{layouts}{default} = $p->{pipeline}{layout};
		delete $p->{pipeline}{layout};
		$key = 'pipeline.layout'; # we're pretending the user did it correctly.
	}
	if (ref($p->{pipeline}{layouts}) eq 'HASH') {
		for (keys %{$p->{pipeline}{layouts}}) {
			if (ref($p->{pipeline}{layouts}{$_})) {
				my $k = $key || "pipeline.layouts.$_";
				push @errors, "`$k' must be a string.";
			}
		}
	} else {
		push @errors, "`pipeline.layouts' must be a map.";
	}

	# validate BOSH directors
	if (ref($p->{pipeline}{boshes}) eq 'HASH') {
		for my $env (keys %{$p->{pipeline}{boshes}}) {
			my $E = eval { $top->load_env($env) };

			# required sub-subkeys
			if ($E && $E->use_create_env) {
				# allowed subkeys for a create-env deploy
				for (keys %{$p->{pipeline}{boshes}{$env}}) {
					push @errors, "Unrecognized `pipeline.boshes[$env].$_' key found."
						unless m/^(alias)$/;
				}
			} else {
				for (qw(url ca_cert username password)) {
					push @errors, "`pipeline.boshes[$env].$_' is required."
						unless $p->{pipeline}{boshes}{$env}{$_};
				}
				# allowed subkeys
				for (keys %{$p->{pipeline}{boshes}{$env}}) {
					push @errors, "Unrecognized `pipeline.boshes[$env].$_' key found."
						unless m/^(url|ca_cert|username|password|alias|genesis_env)$/;
				}
			}
		}
	}

	# validate groups
	if (exists $p->{pipeline}{groups}) {
		if (ref($p->{pipeline}{groups}) eq 'HASH') {
			my @envsaliases = keys %{$p->{pipeline}{boshes}};
			push(@envsaliases, map { $p->{pipeline}{boshes}{$_}{alias} } keys %{$p->{pipeline}{boshes}});
			@envsaliases = grep { defined($_) and $_ ne '' } @envsaliases;
			for my $group (keys %{$p->{pipeline}{groups}}) {
				if (ref($p->{pipeline}{groups}{$group}) ne 'ARRAY') {
					push @errors, "`pipeline.groups.$group' must be an array.";
				}
				for my $job (@{$p->{pipeline}{groups}{$group}}) {
					if ( ! ( grep /^$job$/, @{envsaliases} ) ) {
						push @errors, "`pipeline.groups.$job' is invalid, must be a bosh env name or alias.";
					}
				}
			}
		} else {
			push @errors, "`pipeline.groups' must be a map.";
		}
	}

	# validate auto-update
	if (exists $p->{pipeline}{'auto-update'}) {
		if (ref($p->{pipeline}{'auto-update'}) eq 'HASH') {

			push @errors, "Missing required `pipeline.auto-update.file` key"
				unless $p->{pipeline}{'auto-update'}{file};

			for (keys %{$p->{pipeline}{'auto-update'}}) {
				push @errors, "Unrecognized `pipeline.auto-update.$_' key found."
					unless m/^(file|kit|org|(github_|kit_|)auth_token|api_url|label|period)$/;
			}

			# Populate missing information
			unless (defined($p->{pipeline}{'auto-update'}{api_url})) {
				my $api_url = $top->kit_provider()->base_url;
				if (defined($api_url)) {
					$p->{pipeline}{'auto-update'}{api_url} = $api_url
						unless $api_url eq 'https://api.github.com';
				} else {
					push @errors, "Cannot determine kit provider API url -- please specify in `pipeline.auto-update.api_url' explicitly."
				}
			}
			unless (defined($p->{pipeline}{'auto-update'}{kit})) {
				my @kits = keys(%{$top->local_kits});
				if (scalar(@kits) != 1) {
					push @errors, "Expecting a single local kit, found ${\(scalar(@kits))} - please specify kit name in `pipeline.auto-update.kit`."
				} else {
					$p->{pipeline}{'auto-update'}{kit} = $kits[0];
				}
			}
			$p->{pipeline}{'auto-update'}{org} = $top->kit_provider()->organization
				unless defined($p->{pipeline}{'auto-update'}{org});
		} else {
			push @errors, "`pipeline.auto-update' must be a map.";
		}
	}

	return $p, @errors;
}

sub parse {
	my ($file, $top, $layout) = @_;

	my ($pipeline, @errors) = parse_pipeline($file, $top);
	if (@errors) {
		error "#R{ERRORS encountered} in pipeline definition in #Y{$file}:";
		error "  - #R{$_}" for @errors;
		exit 1;
	}

	unless ($layout) {
		my @layouts = keys %{$pipeline->{pipeline}{layouts}};
		if (scalar(@layouts) == 1) {
			$layout = $layouts[0];
		} elsif (grep {$_ eq 'default'} @layouts) {
			$layout = 'default';
		} else {
			$layout = prompt_for_choice("There is more than one layout, please pick the one you want to use:", $layout);
		}
	}
	my $src = $pipeline->{pipeline}{layouts}{$layout}
		or die "No such layout `${layout}'\n";

	# our internal representation
	my $P = $pipeline;
	$P->{file} = $file;  # the path to the original pipeline file,
	                     # which we need to merge in with the guts.yml
	                     # definition to get the final configuration.

	$P->{auto} = [];     # list of patterns that match environments
	                     # we want concourse to trigger automatically.

	$P->{envs} = [];     # list of all environment names seen in the
	                     # configuration, to be used for validation.

	$P->{aliases} = {};  # map of (env-name -> alias) so that the generated
	                     # pipeline uses short human-readable aliases

	$P->{genesis_envs} = {}; # map of (env-name -> bosh-env-name) for when they are
	                         # not the same.

	$P->{will_trigger} = {}; # map of (A -> [B, C, D]) triggers, where A triggers
	                         # a deploy (or notification) of B, C, and D.  Note that
	                         # the values are lists, because one environment
	                         # can trigger multiple other environments.
	$P->{triggers} = {};     # map of B -> A where B was a deploy triggered
	                         # by a successful deploy of A. Only one environment
	                         # can have triggered each given environment

	# handle yes/no/y/n/true/false/1/0 in our source YAML.
	$P->{pipeline}{tagged}     = yaml_bool($P->{pipeline}{tagged}, 0);
	$P->{pipeline}{public}     = yaml_bool($P->{pipeline}{public}, 0);
	$P->{pipeline}{unredacted} = yaml_bool($P->{pipeline}{unredacted}, 0);
	$P->{pipeline}{ocfp}       = yaml_bool($P->{pipeline}{ocfp}, 0);

	# some default values, if the user didn't supply any
	$P->{pipeline}{vault}{verify} = yaml_bool($P->{pipeline}{vault}{verify}, 1);

	$P->{pipeline}{task}{image}   ||= 'starkandwayne/concourse';
	$P->{pipeline}{task}{version} ||= 'latest';
	$P->{pipeline}{task}{privileged} ||= [];

	# NOTE that source-level mucking about via regexen obliterates
	# all of the line and column information we would expect from
	# a more traditional parser.  If it becomes important to report
	# syntax / semantic errors with line information, this whole
	# parser has to be gutted and re-written.

	$src =~ s/\s*#.*$//gm;   # remove comments (without strings, this is fine)
	$src =~ s/[\r\n]+/ ; /g; # collapse newlines into ';' terminators
	$src =~ s/(^\s+|\s+$)//; # strip leading and trailing whitespace

	# condense the raw stream of tokens into a list or rules,
	# where each rule is itself a list of the significant tokens
	# between two terminators (or begining of file and a terminator)
	#
	# i.e.
	#   [['auto', 'sandbox*'],
	#    ['auto', 'preprod*'],
	#    ['tagged'],
	#    ['sandbox-a', '->', 'sandbox-b']]
	#
	# this structure is designed to be easier to interpret individual
	# rules from, since we can assert against arity and randomly access
	# tokens (i.e. a trigger rule must have '->' at $rule[1]).
	#
	my @rules = ();
	my $rule = [];
	for my $tok (split /\s+/, "$src ;") {
		$tok or die "'$tok' was empty in [$src]!\n";
		if ($tok eq ';') {
			if (@$rule) {
				push @rules, $rule;
				$rule = [];
			}
			next;
		}
		push @$rule, $tok;
	}

	my @auto; # patterns; we'll expand them once we have all the
	          # environments, and then populate $P->{auto};
	my %envs; # de-duplicating map; keys will become $P->{envs}
	for $rule (@rules) {
		my ($cmd, @args) = @$rule;
		if ($cmd eq 'auto') {
			die "The 'auto' directive requires at least one argument.\n"
				unless @args;
			push @auto, @args;
			next;
		}

		# Anything that is not a command must be a pipeline
		if ($P->{pipeline}{boshes}{$cmd}) {
			# Pipeline definition: env [ -> env]*
			my $orig = join ' ', @$rule;
			my ($env, $token);
			while (@$rule) {
				($env, $token, @$rule) = @$rule;
				die "Unknown environment '$env' in pipeline definition '$orig'\n"
					unless ($P->{pipeline}{boshes}{$cmd});
				$envs{$env} = 1;
				if (defined($token)) {
					die "Invalid pipeline definition '$orig': expecting '<env> [-> <env>]...'.\n"
						unless $token eq '->';
					my $target =  $rule->[0];
					die "Missing target after -> in pipeline definition '$orig'\n"
						unless $target;
					push @{$P->{will_trigger}{$env}}, $target;
				}
			}
			next;
		}
		die "Unrecognized environment or configuration directive:  '$cmd'.\n";
	}
	$P->{envs} = [keys %envs];
	$P->{aliases} =      { map { $_ => ($P->{pipeline}{boshes}{$_}{alias}       || $_) } keys %envs};
	$P->{genesis_envs} = { map { $_ => ($P->{pipeline}{boshes}{$_}{genesis_env} || $_) } keys %envs};

	%envs = (); # we'll reuse envs for auto environment de-duplication
	for my $pattern (@auto) {
		my $regex = $pattern;
		$regex =~ s/\*/.*/g;
		$regex = qr/^$regex$/;

		my $n = 0;
		for my $env (@{$P->{envs}}) {
			if ($env =~ $regex) {
				$envs{$env} = 1;
				$n++;
			}
		}
		if ($n == 0) {
			error "#Y{warning}: rule `auto $pattern' did not match any environments...\n";
		}
	}
	$P->{auto} = [keys %envs];

	# make sure we have a BOSH director for each seen environment.
	# (thanks to read_pipeline, we know any extant BOSH director configs are good)
	for my $env (@{$P->{envs}}) {
		die "No BOSH director configuration found for $env (at `pipeline.boshes[$env]').\n"
			unless $P->{pipeline}{boshes}{$env};
	}

	# figure out who triggers each environment.
	# this is an inversion of the directed acyclic graph that we
	# are storing in {triggers}.
	#
	# this means that it is illegal for a given environment to be
	# triggererd by more than one other environment.  this decision
	# was made to simplify implementation, and was deemed to not
	# impose overly much on desired pipeline structure.
	my $triggers = {};
	for my $a (keys %{$P->{will_trigger}}) {
		for my $b (@{$P->{will_trigger}{$a}}) {
			# $a triggers $b, that is $b won't deploy unti we
			# see a successful deploy (+test) of the $a environment
			die "Environment '$b' is already being triggered by environment '$triggers->{$b}'.\nIt is illegal to trigger an environment more than once.\n"
				if $triggers->{$b} and $triggers->{$b} ne $a;
			$triggers->{$b} = $a;
		}
	}
	$P->{triggers} = $triggers;

	return ($P, $layout);
}

sub pipeline_tree {
	my ($prefix, $env, $trees) = @_;
	#
	# sandbox
	#  |--> preprod
	#  |     |--> prod
	#  |     |--> prod-2
	#  |     `--> some-prod
	#  |
	#  `--> other-preprod
	#        `--> other-prod
	#

	print "$env\n";
	my $n = @{$trees->{$env} || []};
	for my $kid (sort @{$trees->{$env} || []}) {
		$n--;
		if ($n) {
			print "$prefix  |--> ";
			pipeline_tree("$prefix  |   ", $kid, $trees);
		} else {
			print "$prefix  `--> ";
			pipeline_tree("$prefix      ", $kid, $trees);
		}
	}
}

sub generate_pipeline_human_description {
	my ($self) = @_;
	my $pipeline = $self;

	my %auto = map { $_ => 1 } @{$pipeline->{auto}};

	my %trees;
	my %envs = map { $_ => 1 } @{$pipeline->{envs}};
	for my $b (keys %{$pipeline->{triggers}}) {
		my $a = $pipeline->{triggers}{$b};
		push @{$trees{$a}}, $b;
		delete $envs{$b};
	}
	for (sort keys %envs) {
		pipeline_tree("", $_, \%trees);
		print "\n";
	}
}

sub generate_pipeline_graphviz_source {
	my ($self) = @_;
	my $pipeline = $self;

	my $out = "";
	open my $fh, ">", \$out;
	print $fh "digraph {\n";
	print $fh "  rankdir = LR; node [shape=none]; edge [color=\"#777777\",fontcolor=\"red\"];\n";

	my %auto = map { $_ => 1 } @{$pipeline->{auto}};
	for my $b (keys %{$pipeline->{triggers}}) {
		my $a = $pipeline->{triggers}{$b};
		(my $b1 = $b) =~ s/-/_/g;
		(my $a1 = $a) =~ s/-/_/g;
		print $fh "  $a1 [label=\"$a\"];\n";
		print $fh "  $b1 [label=\"$b\"];\n";
		if ($auto{$b}) {
			print $fh "  $a1 -> $b1;\n";
		} else {
			print $fh "  $a1 -> $b1 [label=\"manual\"];\n";
		}
	}

	print $fh "}\n";
	close $fh;
	return $out;
}

sub generate_pipeline_concourse_yaml {
	my ($pipeline, $top) = @_;

	$pipeline->{pipeline}{notifications} ||= 'inline';
	my $group_notifications = $pipeline->{pipeline}{notifications} eq 'grouped';
	my $inline_notifications = $pipeline->{pipeline}{notifications} eq 'inline';

	my $dir = workdir;
	open my $OUT, ">", "$dir/guts.yml"
		or die "Failed to generate Concourse Pipeline YAML configuration: $!\n";

	# Figure out what environments auto-trigger, and what don't
	my %auto = map { $_ => 1 } @{$pipeline->{auto}};

	# CONCOURSE: pipeline (+params) {{{
	print $OUT <<"EOF";
---
pipeline:
EOF
	# -- pipeline.git {{{
	my $git_credentials;
	if ($pipeline->{pipeline}{git}{private_key}) {
		$git_credentials = "    private_key: |-\n      ".join("\n      ",split("\n",$pipeline->{pipeline}{git}{private_key}));
	} else {
		my $git_password_as_yaml = string_to_yaml($pipeline->{pipeline}{git}{password});
		$git_credentials = "    username:    $pipeline->{pipeline}{git}{username}\n    password:    \"$git_password_as_yaml\"";
	}
	print $OUT <<"EOF";
  git:
    uri:         $pipeline->{pipeline}{git}{uri}
    branch:      master
$git_credentials
    config:
      icon: github
    commits:
      user_name:  $pipeline->{pipeline}{git}{commits}{user_name}
      user_email: $pipeline->{pipeline}{git}{commits}{user_email}
EOF
  # }}}
	# -- pipeline.vault {{{
	# programmatically determine if we should pull pipeline vault creds from vault, or operator needs to specify.
	if (safe_path_exists "secret/exodus/ci/genesis-pipelines") {
		print $OUT <<'EOF';
  vault:
    role:   (( vault "secret/exodus/ci/genesis-pipelines:approle-id" ))
    secret: (( vault "secret/exodus/ci/genesis-pipelines:approle-secret" ))
EOF
	} else {
		print $OUT <<'EOF';
  vault:
    role:   (( param "Please run the 'setup-approle' addon in the Concourse kit for this environment, or specify your own AppRole ID." ))
    secret: (( param "Please run the 'setup-approle' addon in the Concourse kit for this environment, or specify your own AppRole secret." ))
EOF
	} # }}}
	# -- pipeline.slack {{{
	if ($pipeline->{pipeline}{slack}) {
		print $OUT <<'EOF';
  slack:
    webhook:  (( param "Please provide a Slack Integration WebHook." ))
    channel:  (( param "Please specify the channel (#name) or user (@user) to send messages to." ))
    username: runwaybot
    icon:     http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
EOF
	} # }}}
	# -- pipeline.hipchat {{{
	if ($pipeline->{pipeline}{hipchat}) {
		print $OUT <<'EOF';
  hipchat:
    url:      http://api.hipchat.com
    room_id:  (( param "Please specify the room ID that Concourse should send HipChat notifications to" ))
    token:    (( param "Please specify the HipChat authentication token" ))
    notify:   false
    username: runwaybot
EOF
	} # }}}
	# -- pipeline.stride {{{
	if ($pipeline->{pipeline}{stride}) {
		print $OUT <<'EOF';
  stride:
    client_id: (( param "Please specify the client ID for the Stride app that Concourse should send notifications as" ))
    client_secret: (( param "Please specify the client secret for the Stride app that Concourse should send notifications as" ))
    cloud_id: (( param "Please specify the Stride cloud ID that Concourse should send notifications to" ))
    conversation: (( param "Please specify the Stride conversation name that Concourse should send notifications to" ))
EOF
	} # }}}
	# -- pipeline.email {{{
	if ($pipeline->{pipeline}{email}) {
		print $OUT <<'EOF';
  email:
    to:   (( param "Please provide a list of email addresses to send 'Pending Deployment' notifications to." ))
    from: (( param "Please specify a 'From:' account (an email address).  Email will be sent from this address." ))
    smtp:
      username: (( param "Please provide a username to authenticate against your Mail Server (SMTP) host." ))
      password: (( param "Please provide a password to authenticate against your Mail Server (SMTP) host." ))
      host:     (( param "Please specify the FQDN or IP address of your Mail Server (SMTP) host." ))
      port:     587
EOF
	} # }}}
	# -- pipeline.locker {{{
	if ($pipeline->{pipeline}{locker}{url}) {
		print $OUT <<'EOF';
  locker:
    url:                 (( param "Please provide the URI to the locker API" ))
    username:            (( param "Please provide the locker API username" ))
    password:            (( param "Please provide the locker API password" ))
    # FIXME until we have service discovery (bosh dns) to reliably know the
    #       locker hostname, and have a ca_cert generated in the concourse kit,
    #       we need to turn on skip_ssl_validation, and nullify the ca_cert by default
    ca_cert:             ~
    skip_ssl_validation: true

EOF
	} # }}}
	# -- pipeline.auto-update {{{
	if (defined($pipeline->{pipeline}{'auto-update'}{file})) {
		print $OUT <<"EOF";
  auto-update:
    file:    (( param "Please provide the file that specifies the kit version" ))
    kit:     $pipeline->{pipeline}{'auto-update'}{kit}
    org:     $pipeline->{pipeline}{'auto-update'}{org}
EOF
		if ($pipeline->{pipeline}{'auto-update'}{api_url}) {
			print $OUT "    api_url: $pipeline->{pipeline}{'auto-update'}{api_url}\n";
		}
	} # }}}
	# }}}
	# CONCOURSE: groups, and resource configuration {{{
	print $OUT <<EOF;
groups:
EOF
	if (ref($pipeline->{pipeline}{groups}) eq 'HASH') {
		my @group_notifications;
		foreach my $group (sort(keys %{$pipeline->{pipeline}{groups}})) {
			print $OUT <<EOF;
  - name: $group
    jobs:
EOF
			foreach my $job (sort(@{$pipeline->{pipeline}{groups}{$group}})) {
				if ( grep ( /^$job$/, @{$pipeline->{envs}} ) ) {
					my $jobalias = $pipeline->{aliases}{$job};
					print $OUT "    - $jobalias-".$top->type."\n";
					if (! $auto{$job}) {
						my $job_entry = "notify-$jobalias-".$top->type."-changes";
						if ($group_notifications) {
							push @group_notifications, $job_entry;
						} else {
							print $OUT "    - $job_entry\n";
						}
					}
				} else {
					print $OUT "    - $job-".$top->type."\n";
					my $autoname = "";
					for my $env (@{$pipeline->{envs}}) {
						if ( grep /^$job$/,$pipeline->{pipeline}->{boshes}{$env}{alias} ) {
							$autoname = $env;
						}
					}
					if (! $auto{$autoname}) {
						my $job_entry = "notify-$job-".$top->type."-changes";
						if ($group_notifications) {
							push @group_notifications, $job_entry;
						} else {
							print $OUT "    - $job_entry\n";
						}
					}
				}
			}
		}
		if ($group_notifications && @group_notifications) {
			print $OUT <<EOF;
  - name: notifications
    jobs:
EOF
			print $OUT "    - $_\n" for (uniq(@group_notifications));
		}
	} else {
		print $OUT <<EOF;
  - name: $pipeline->{pipeline}{name}
    jobs:
EOF

		print $OUT "    - $_\n" for sort map { "$pipeline->{aliases}{$_}-" . $top->type } @{$pipeline->{envs}};
		print $OUT <<EOF if $group_notifications;
  - name: notifications
    jobs:
EOF
		print $OUT "    - notify-$_-changes\n" for sort map { "$pipeline->{aliases}{$_}-" . $top->type }
		grep { ! $auto{$_} } @{$pipeline->{envs}};
	}
	if (defined($pipeline->{pipeline}{'auto-update'}{file})) {
		print $OUT <<EOF;
  - name: genesis-updates
    jobs:
    - update-genesis-assets
EOF
	}
	my ($git_resource_creds,$git_env_creds);
	if ($pipeline->{pipeline}{git}{private_key}) {
		$git_resource_creds = "      private_key: (( grab pipeline.git.private_key ))";
		$git_env_creds = "            GIT_PRIVATE_KEY:      (( grab pipeline.git.private_key ))";
	} else {
		$git_resource_creds = "      username:    (( grab pipeline.git.username ))\n      password:    (( grab pipeline.git.password ))";
		$git_env_creds = "            GIT_USERNAME:         (( grab pipeline.git.username ))\n            GIT_PASSWORD:         (( grab pipeline.git.password || \"\" ))";
	}
	my $git_genesis_root = $pipeline->{pipeline}{git}{root} ne '.' ? "            GIT_GENESIS_ROOT:     $pipeline->{pipeline}{git}{root}\n" : "";

	print $OUT <<EOF;

resources:
  - name: git
    type: git
    .: (( inject pipeline.git.config ))
    source:
      branch:      (( grab pipeline.git.branch ))
$git_resource_creds
      uri:         (( grab pipeline.git.uri ))
EOF
   # }}}
	# CONCOURSE: env-specific resource configuration {{{
	my $path_root = $pipeline->{pipeline}{git}{root}."/";
	$path_root = "" if $path_root eq "./";
	my @base_paths = qw[
		.genesis/bin/genesis
		.genesis/kits
		.genesis/config
	];
	for my $env (sort @{$pipeline->{envs}}) {
		my $E = $top->load_env($env);
		# YAML snippets, to make the print's less obnoxious {{{
		#
		# 1) do we tag the jobs so that they are constrained to a
		#   specific subset of concourse workers? ('tagged' directive)
		my $tag_yaml = $pipeline->{pipeline}{tagged} ? "tags: [$env]" : "";

		my $alias = $pipeline->{aliases}{$env};
		print $OUT <<EOF;
  - name: ${alias}-changes
    type: git
    .: (( inject pipeline.git.config ))
    source:
      .: (( inject resources.git.source ))
      paths:
EOF
		# }}}

		# watch the common files in our predecessor cache - for example,
		# if us-west-1-sandbox-a triggers us-west-1-preprod-a, then
		# preprod-a would watch the cache of sandbox-a for:
		#
		#    us.yml
		#    us-west.yml
		#    us-west-1.yml
		#
		# and it would only check the top-level root for it's own files:
		#
		#    us-west-1-preprod.yml
		#    us-west-1-preprod-a.yml
		#
		if ($pipeline->{triggers}{$env}) {
			my $trigger = $pipeline->{triggers}{$env};
			my $lineage = $E->relate($trigger, ".genesis/cached/$trigger");
			my @unique = map {$_ =~ s#^./##; $_} @{$lineage->{unique}};
			my @common = (
				".genesis/cached/$trigger/ops/*",
				".genesis/cached/$trigger/kit-overrides.yml",
				map {$_ =~ s#^./##; $_} @{$lineage->{common}},
			);
			print $OUT "        - $path_root$_\n" for @unique;
			print $OUT <<EOF;

  - name: ${alias}-cache
    type: git
    .: (( inject pipeline.git.config ))
    source:
      .: (( inject resources.git.source ))
      paths:
EOF
			print $OUT "# $trigger -> $env\n";
			print $OUT "        - $path_root$_\n" for (@base_paths,@common);
		} else {
			print $OUT "        - $path_root$_\n" for (
				@base_paths, "ops/*", "kit-overrides.yml",
				map {$_ =~ s#^./##; $_} $E->potential_environment_files()
			);
		}
		unless ($E->use_create_env) {
			my $config_name = 'default';
			if ($pipeline->{pipeline}{ocfp}) {
				$config_name = $pipeline->{genesis_envs}{$env};
			}
			print $OUT <<EOF;

  - name: ${alias}-cloud-config
    type: bosh-config
    icon: script-text
    $tag_yaml
    source:
      target: $pipeline->{pipeline}{boshes}{$env}{url}
      client: $pipeline->{pipeline}{boshes}{$env}{username}
      client_secret: $pipeline->{pipeline}{boshes}{$env}{password}
      ca_cert: |
EOF
			for (split /\n/, $pipeline->{pipeline}{boshes}{$env}{ca_cert}) {
				print $OUT <<EOF;
         $_
EOF
			}
			print $OUT <<EOF;
      config: cloud
      name: $config_name

  - name: ${alias}-runtime-config
    type: bosh-config
    icon: script-text
    $tag_yaml
    source:
      target: $pipeline->{pipeline}{boshes}{$env}{url}
      client: $pipeline->{pipeline}{boshes}{$env}{username}
      client_secret: $pipeline->{pipeline}{boshes}{$env}{password}
      ca_cert: |
EOF
			for (split /\n/, $pipeline->{pipeline}{boshes}{$env}{ca_cert}) {
				print $OUT <<EOF;
        $_
EOF
			}
			print $OUT <<EOF;
      config: runtime
      name: $config_name

EOF
		}
		# Locker Resources
		#
		# There are two locker resources: one for the BOSH director being deployed
		# to, and one for the deployment being done.  The BOSH director must be
		# named for the BOSH director target for the current environment (not used
		# if it's a proto-BOSH.  This is done so that the deployment lock for BOSH
		# deployments matches the bosh lock for environments being deployed by it.
		if ($pipeline->{pipeline}{locker}{url}) {
			my $deployment_suffix = $top->type;
			print $OUT <<EOF unless ($E->use_create_env);
  - name: ${alias}-bosh-lock
    type: locker
    icon: shield-lock-outline
    $tag_yaml
    source:
      locker_uri: (( grab pipeline.locker.url ))
      username: (( grab pipeline.locker.username ))
      password: (( grab pipeline.locker.password ))
      skip_ssl_validation: (( grab pipeline.locker.skip_ssl_validation ))
      ca_cert: (( grab pipeline.locker.ca_cert ))
      bosh_lock: $pipeline->{pipeline}{boshes}{$env}{url}
EOF
			print $OUT <<EOF;
  - name: ${alias}-deployment-lock
    type: locker
    icon: shield-lock-outline
    $tag_yaml
    source:
      locker_uri: (( grab pipeline.locker.url ))
      username: (( grab pipeline.locker.username ))
      password: (( grab pipeline.locker.password ))
      skip_ssl_validation: (( grab pipeline.locker.skip_ssl_validation ))
      ca_cert: (( grab pipeline.locker.ca_cert ))
      lock_name:  ${env}-${deployment_suffix}

EOF
		}
	}
	# }}}
	# CONCOURSE: notification resource configuration {{{
	if ($pipeline->{pipeline}{slack}) {
		print $OUT <<'EOF';
  - name: slack
    type: slack-notification
    icon: slack
    source:
      url: (( grab pipeline.slack.webhook ))

EOF
	}
	if ($pipeline->{pipeline}{hipchat}) {
		print $OUT <<'EOF';
  - name: hipchat
    type: hipchat-notification
    icon: bell-ring
    source:
      hipchat_server_url: (( grab pipeline.hipchat.url ))
      room_id:  (( grab pipeline.hipchat.room_id ))
      token:    (( grab pipeline.hipchat.token ))
EOF
	}
	if ($pipeline->{pipeline}{stride}) {
		print $OUT <<'EOF';
  - name: stride
    type: stride-notification
    icon: bell-ring
    source:
      client_id: (( grab pipeline.stride.client_id ))
      client_secret: (( grab pipeline.stride.client_secret ))
      cloud_id: (( grab pipeline.stride.cloud_id ))
EOF
	}
	if ($pipeline->{pipeline}{email}) {
		print $OUT <<'EOF';
  - name: email
    type: email
    icon: email-send-outline
    source:
      to:   (( grab pipeline.email.to ))
      from: (( grab pipeline.email.from ))
      smtp:
        host:     (( grab pipeline.email.smtp.host ))
        port:     (( grab pipeline.email.smtp.port ))
        username: (( grab pipeline.email.smtp.username ))
        password: (( grab pipeline.email.smtp.password ))
EOF
	} # }}}
# CONCOURSE: genesis-assets resource configuration {{{
	if (defined($pipeline->{pipeline}{'auto-update'}{file})) {
		print $OUT <<EOF;
  - name: kit-release
    icon: package-variant
    type: github-release
    check_every: (( grab pipeline.auto-update.period || "24h" ))
    source:
      user:         (( grab pipeline.auto-update.org ))
      repository:   (( concat pipeline.auto-update.kit "-genesis-kit" ))
      access_token: (( grab pipeline.auto-update.kit_auth_token || pipeline.auto-update.auth_token || "" ))
EOF
		print $OUT <<EOF if defined($pipeline->{pipeline}{'auto-update'}{api_url});
      github_api_url: (( grab pipeline.auto-update.api_url ))
EOF
		print $OUT <<EOF;
  - name: genesis-release
    type: github-release
    icon: leaf
    check_every: (( grab pipeline.auto-update.period || "24h" ))
    source:
      user:         "genesis-community"
      repository:   "genesis"
      access_token: (( grab pipeline.auto-update.genesis_auth_token || pipeline.auto-update.auth_token || "" ))
EOF
	}

	# }}}
	my ($registry_prefix, $registry_creds, $registry_password_as_yaml) = ("", "", "");
	if ($pipeline->{pipeline}{registry}{uri}) {
		$registry_prefix = $pipeline->{pipeline}{registry}{uri} . "/";
		if ($pipeline->{pipeline}{registry}{username}) {
			$registry_password_as_yaml = string_to_yaml($pipeline->{pipeline}{registry}{password});
			$registry_creds = <<EOF
      username: $pipeline->{pipeline}{registry}{username}
      password: "$registry_password_as_yaml"
EOF
		}
	}
	# CONCOURSE: resource types {{{
	print $OUT <<EOF;

resource_types:
  - name: script
    type: registry-image
    source:
      repository: ${registry_prefix}cfcommunity/script-resource
${registry_creds}
  - name: email
    type: registry-image
    source:
      repository: ${registry_prefix}pcfseceng/email-resource
${registry_creds}
  - name: slack-notification
    type: registry-image
    source:
      repository: ${registry_prefix}cfcommunity/slack-notification-resource
${registry_creds}
  - name: hipchat-notification
    type: registry-image
    source:
      repository: ${registry_prefix}cfcommunity/hipchat-notification-resource
${registry_creds}
  - name: stride-notification
    type: registry-image
    source:
      repository: ${registry_prefix}starkandwayne/stride-notification-resource
${registry_creds}
  - name: bosh-config
    type: registry-image
    source:
      repository: ${registry_prefix}cfcommunity/bosh-config-resource
${registry_creds}
  - name: locker
    type: registry-image
    source:
      repository: ${registry_prefix}cfcommunity/locker-resource
${registry_creds}
EOF
	# }}}
	print $OUT <<EOF;
jobs:
EOF
	if ($pipeline->{pipeline}{registry}{uri} && $pipeline->{pipeline}{registry}{username}) {
		# We redefine registry credentials with different indenting
		$registry_creds = <<EOF
              username: $pipeline->{pipeline}{registry}{username}
              password: "$registry_password_as_yaml"
EOF
	}
	for my $env (sort @{$pipeline->{envs}}) {
		my $E = $top->load_env($env);
		# CONCOURSE: env-specific job configuration {{{

		# YAML snippets, to make the print's less obnoxious {{{
		#
		# 1) do we tag the jobs so that they are constrained to a
		#   specific subset of concourse workers? ('tagged' directive)
		my $tag_yaml = $pipeline->{pipeline}{tagged} ? "tags: [$env]" : "";

		# 2) Are we auto-triggering this environment?
		my $trigger = $auto{$env} ? "true" : "false";

		# 3) what is our deployment suffix?
		my $deployment_suffix = $top->type;

		# 4) what previous (triggering) job/env do we need to wait
		#    on for our cached configuration changes
		my $passed =$pipeline->{triggers}{$env} ? $pipeline->{triggers}{$env} : "";
		my $passed_alias = $passed ? "$pipeline->{aliases}{$passed}-$deployment_suffix" : "";

		# 5) Alias of environment for concourse readabilitys
		my $alias = $pipeline->{aliases}{$env};

		# 6) If we have a previous environment, generate input definition
		#    too look at our cache
		my $cache_yaml = "";
		if ($pipeline->{triggers}{$env}) {
			if ($trigger eq "true" || !$inline_notifications) {
				$cache_yaml = sprintf("- { get: $alias-cache, passed: [%s], trigger: %s }", $passed_alias, $trigger)
			} else {
				$cache_yaml = sprintf("- { get: $alias-cache, passed: [notify-%s-%s-changes], trigger: false }", $alias, $deployment_suffix);
			}
		}
		my $notify_cache = $pipeline->{triggers}{$env} ?
			"- { get: $alias-cache, passed: [$passed_alias], trigger: true }" : "";

		# 7) If we don't auto-trigger, we should use passed as our notify resource
		#    otherwise, use the live value
		my $changes_yaml = ($trigger eq "true" || !$inline_notifications) ?
			sprintf("- { get: %s-changes, trigger: %s }", $alias, $trigger) :
			sprintf("- { get: %s-changes, trigger: false, passed: [notify-%s-%s-changes]}", $alias, $alias, $deployment_suffix);

		# 8) Build notifications for non-automatic deployments that sense changes
		my $changes_staged_notification = _gen_notifications($pipeline,
			"Changes are staged to be deployed to $env-$deployment_suffix, " .
			"see notify-$alias-$deployment_suffix-changes job for change summary, " .
			"then schedule and run a deploy via Concourse", "changes-staged");

		# 9) Build notifications for failed deployments
		my $deployment_failure_notification = _gen_notifications($pipeline,
			"Concourse deployment to $env-$deployment_suffix failed", "failure");

		# 10) Build notifications for successful deployments
		my $deployment_success_notification = _gen_notifications($pipeline,
			"Concourse successfully deployed $env-$deployment_suffix", "success");

		# 11) directory to find the genesis binary in (use previous env cache if present, else local-changes
		my $genesis_srcdir = my $genesis_bindir = $passed ? "$alias-cache" : "$alias-changes";
		$genesis_bindir .= "/$pipeline->{pipeline}{git}{root}"
		  if ($pipeline->{pipeline}{git}{root} ne ".");

		# }}}

		if ($trigger eq "false" ) {
			# notify job for non-automatic deploys {{{
			print $OUT <<EOF;
  - name: notify-$alias-$deployment_suffix-changes
    public: true
    serial: true
    plan:
      - in_parallel:
        - { get: $alias-changes, trigger: true }
        $notify_cache
EOF
			unless ($E->use_create_env) {
				print $OUT <<EOF;
        - get: $alias-cloud-config
          $tag_yaml
          trigger: true
        - get: $alias-runtime-config
          $tag_yaml
          trigger: true
EOF
			}
			print $OUT <<EOF;
      - task: show-pending-changes
        $tag_yaml
        config:
          platform: linux
          image_resource:
            type: registry-image
            source:
${registry_creds}
              repository: ${registry_prefix}$pipeline->{pipeline}{task}{image}
              tag:        $pipeline->{pipeline}{task}{version}
          params:
            GENESIS_HONOR_ENV:    1
            CI_NO_REDACT:         $pipeline->{pipeline}{unredacted}
            CURRENT_ENV:          $env
            PREVIOUS_ENV:         ${\($passed || '~')}
            CACHE_DIR:            $alias-cache
            OUT_DIR:              out/git
            WORKING_DIR:          $alias-changes # work out of latest changes for this environment
            GIT_BRANCH:           (( grab pipeline.git.branch ))
            GIT_AUTHOR_NAME:      $pipeline->{pipeline}{git}{commits}{user_name}
            GIT_AUTHOR_EMAIL:     $pipeline->{pipeline}{git}{commits}{user_email}
$git_genesis_root$git_env_creds
            BOSH_NON_INTERACTIVE: true
            VAULT_ROLE_ID:        (( grab pipeline.vault.role ))
            VAULT_SECRET_ID:      (( grab pipeline.vault.secret ))
            VAULT_ADDR:           $pipeline->{pipeline}{vault}{url}
            VAULT_SKIP_VERIFY:    ${\($pipeline->{pipeline}{vault}{verify} ? 'false' : 'true')}
EOF
		print $OUT "            VAULT_NO_STRONGBOX:   \"true\"\n"
			if $pipeline->{pipeline}{vault}{'no-strongbox'};
		print $OUT "            VAULT_NAMESPACE:      $pipeline->{pipeline}{vault}{namespace}\n"
			if $pipeline->{pipeline}{vault}{namespace};
		print $OUT <<EOF if $pipeline->{pipeline}{debug};
            DEBUG:                $pipeline->{pipeline}{debug}
EOF
		print $OUT <<EOF;

          run:
            # run from inside the environment changes to get latest cache + regular data
            # but use the executable from genesis
            path: $genesis_bindir/.genesis/bin/genesis
            args: [ci-show-changes]
          inputs:
            - { name: $alias-changes } # deploy from latest changes
EOF
		print $OUT <<EOF if $passed;
            - { name: $alias-cache }
EOF
		print $OUT <<EOF;
      - $changes_staged_notification
EOF
		}
		# }}}
		print $OUT <<EOF;
  - name: $alias-$deployment_suffix
    public: true
    serial: true
    plan:
    - on_failure:
        $deployment_failure_notification
      on_success:
        $deployment_success_notification
EOF
		if ($pipeline->{pipeline}{locker}{url}) {
			print $OUT <<EOF;
      ensure:
        do:
EOF
			# <alias>-bosh-lock is used to prevent the parent bosh from upgrading while we deploy
			# - not necessary for create-env
			print $OUT <<EOF unless ($E->use_create_env);
        - put: ${alias}-bosh-lock
          $tag_yaml
          params:
            lock_op: unlock
            key: dont-upgrade-bosh-on-me
            locked_by: ${env}-${deployment_suffix}
EOF
			print $OUT <<EOF;
        - put: ${alias}-deployment-lock
          $tag_yaml
          params:
            lock_op: unlock
            key: i-need-to-deploy-myself
            locked_by: ${env}-${deployment_suffix}
EOF
		}
		print $OUT <<EOF;
      do:
EOF
		if ($pipeline->{pipeline}{locker}{url}) {

			# <alias>-bosh-lock is used to prevent the parent bosh from upgrading while we deploy
			# - not necessary for create-env
			print $OUT <<EOF unless ($E->use_create_env);
      - put: ${alias}-bosh-lock
        $tag_yaml
        params:
          lock_op: lock
          key: dont-upgrade-bosh-on-me
          locked_by: ${env}-${deployment_suffix}
EOF
			print $OUT <<EOF;
      - put: ${alias}-deployment-lock
        $tag_yaml
        params:
          lock_op: lock
          key: i-need-to-deploy-myself
          locked_by: ${env}-${deployment_suffix}
EOF
		}
		print $OUT <<EOF;
      - in_parallel:
EOF
		# only add cloud/runtime config on true-triggers, otherwise it goes in notifications
		# also make sure that we are not deploying with create-env (no cloud/runtime config for that scenario)
		if (! $E->use_create_env && $trigger eq "true") {
			print $OUT <<EOF;
        - get: $alias-cloud-config
          $tag_yaml
          trigger: true
        - get: $alias-runtime-config
          $tag_yaml
          trigger: true
EOF
		}
		print $OUT <<EOF;
        # genesis itself handles the propagation of files from successful environment
        # to the next. anything triggering env-changes should be considered to have passed
        # the previous environment, if in cached, and if not, should be triggered
        $changes_yaml
        $cache_yaml
EOF
		print $OUT <<EOF;
      - task: bosh-deploy
        $tag_yaml
        config:
          platform: linux
          image_resource:
            type: registry-image
            source:
${registry_creds}
              repository: ${registry_prefix}$pipeline->{pipeline}{task}{image}
              tag:        $pipeline->{pipeline}{task}{version}
          params:
            GENESIS_HONOR_ENV:    1
            CI_NO_REDACT:         $pipeline->{pipeline}{unredacted}
            CURRENT_ENV:          $env
            PREVIOUS_ENV:         ${\($passed || '~')}
            CACHE_DIR:            $alias-cache
            OUT_DIR:              out/git
            WORKING_DIR:          $alias-changes # work out of latest changes for this environment
            GIT_BRANCH:           (( grab pipeline.git.branch ))
            GIT_AUTHOR_NAME:      $pipeline->{pipeline}{git}{commits}{user_name}
            GIT_AUTHOR_EMAIL:     $pipeline->{pipeline}{git}{commits}{user_email}
$git_genesis_root$git_env_creds
            BOSH_NON_INTERACTIVE: true
            VAULT_ROLE_ID:        (( grab pipeline.vault.role ))
            VAULT_SECRET_ID:      (( grab pipeline.vault.secret ))
            VAULT_ADDR:           $pipeline->{pipeline}{vault}{url}
            VAULT_SKIP_VERIFY:    ${\($pipeline->{pipeline}{vault}{verify} ? 'false' : 'true')}
EOF
		print $OUT "            VAULT_NO_STRONGBOX:   \"true\"\n"
			if $pipeline->{pipeline}{vault}{'no-strongbox'};
		print $OUT "            VAULT_NAMESPACE:      $pipeline->{pipeline}{vault}{namespace}\n"
			if $pipeline->{pipeline}{vault}{namespace};
		print $OUT <<EOF if $pipeline->{pipeline}{debug};
            DEBUG:                $pipeline->{pipeline}{debug}
EOF
		print $OUT <<EOF;

          run:
            # run from inside the environment changes to get latest cache + regular data
            # but use the executable from genesis
            path: $genesis_bindir/.genesis/bin/genesis
            args: [ci-pipeline-deploy]
          inputs:
            - { name: $alias-changes } # deploy from latest changes
EOF
		print $OUT <<EOF if $passed;
            - { name: $alias-cache }
EOF
		print $OUT <<EOF;
          outputs:
            - { name: out }

        # push the deployment changes up to git, even if the deploy fails, to save
        # files for create-env + reflect "live" state
        ensure:
          put: git
          params:
            repository: out/git
EOF
		my $privileged = (grep {$_ eq "$alias"} @{$pipeline->{pipeline}{task}{privileged}});
		if ($privileged) {
			print $OUT <<EOF;
        privileged: true
EOF
		}

		# CONCOURSE: run optional errands as tasks - non-create-env only (otherwise no bosh to run the errand) {{{
		unless ($E->use_create_env) {
			for my $errand_name (@{$pipeline->{pipeline}{errands}}) {
				print $OUT <<EOF;
        # run errands against the deployment
      - task: $errand_name-errand
        $tag_yaml
        config:
          platform: linux
          image_resource:
            type: registry-image
            source:
${registry_creds}
              repository: ${registry_prefix}$pipeline->{pipeline}{task}{image}
              tag:        $pipeline->{pipeline}{task}{version}
          params:
            GENESIS_HONOR_ENV:    1
            CI_NO_REDACT:         $pipeline->{pipeline}{unredacted}
            CURRENT_ENV:          $env
            ERRAND_NAME:          $errand_name
            VAULT_ROLE_ID:        (( grab pipeline.vault.role ))
            VAULT_SECRET_ID:      (( grab pipeline.vault.secret ))
            VAULT_ADDR:           $pipeline->{pipeline}{vault}{url}
            VAULT_SKIP_VERIFY:    ${\($pipeline->{pipeline}{vault}{verify} ? 'false' : 'true')}
EOF
			print $OUT "            VAULT_NO_STRONGBOX:   \"true\"\n"
				if $pipeline->{pipeline}{vault}{'no-strongbox'};
			print $OUT "            VAULT_NAMESPACE:      $pipeline->{pipeline}{vault}{namespace}\n"
				if $pipeline->{pipeline}{vault}{namespace};
			print $OUT <<EOF if $pipeline->{pipeline}{debug};
            DEBUG:                $pipeline->{pipeline}{debug}
EOF
			my $errand_subdir = ($pipeline->{pipeline}{git}{root} eq '.') ? "" :
			  "/$pipeline->{pipeline}{git}{root}";

			print $OUT <<EOF;

          run:
            path: ../../$genesis_bindir/.genesis/bin/genesis
            dir:  out/git$errand_subdir
            args: [ci-pipeline-run-errand]
          inputs:
            - name: out
            - name: $genesis_srcdir
EOF
			}
		}
		# }}}
		print $OUT <<EOF;
      - task: generate-cache
        $tag_yaml
        config:
          inputs:
          - { name: out }
          - { name: $genesis_srcdir }
          outputs:
          - { name: cache-out }
          run:
            path: $genesis_bindir/.genesis/bin/genesis
            args: [ci-generate-cache]
          params:
            GENESIS_HONOR_ENV:    1
            CI_NO_REDACT:         $pipeline->{pipeline}{unredacted}
            CURRENT_ENV:          $env
EOF
		print $OUT <<EOF if $passed;
            PREVIOUS_ENV:         ${\($passed || '~')}
            CACHE_DIR:            $alias-cache
EOF
		print $OUT <<EOF;
            WORKING_DIR:          out/git
            OUT_DIR:              cache-out/git
            GIT_BRANCH:           (( grab pipeline.git.branch ))
            GIT_AUTHOR_NAME:      $pipeline->{pipeline}{git}{commits}{user_name}
            GIT_AUTHOR_EMAIL:     $pipeline->{pipeline}{git}{commits}{user_email}
$git_genesis_root$git_env_creds
EOF

		print $OUT <<EOF if $pipeline->{pipeline}{debug};
            DEBUG:                $pipeline->{pipeline}{debug}
EOF
		print $OUT <<EOF;
          platform: linux
          image_resource:
            type: registry-image
            source:
${registry_creds}
              repository: ${registry_prefix}$pipeline->{pipeline}{task}{image}
              tag:        $pipeline->{pipeline}{task}{version}
      - put: git
        params:
          repository: cache-out/git
EOF

		for my $push_env (@{$pipeline->{will_trigger}{$env}}) {
			print $OUT <<EOF;
      - put: $pipeline->{aliases}{$push_env}-cache
        params:
          repository: cache-out/git
EOF
		}
	# }}}
	}

	# CONCOURSE: update-genesis-asses job configuration {{{
	if (defined($pipeline->{pipeline}{'auto-update'}{file})) {
		my $git_genesis_dir = 'git';
		my $genesis_config_path = '';
		my $path_prefix = '';
		my $subdir_msg = '';
		if ($pipeline->{pipeline}{git}{root} ne '.') {
			$git_genesis_dir .= "/$pipeline->{pipeline}{git}{root}";
			$genesis_config_path = " -C '$pipeline->{pipeline}{git}{root}'";
			$path_prefix = "$pipeline->{pipeline}{git}{root}/";
			$subdir_msg = " under $pipeline->{pipeline}{git}{root}";
		}
		if ($pipeline->{pipeline}{registry}{uri} && $pipeline->{pipeline}{registry}{username}) {
			my $registry_password_as_yaml = string_to_yaml($pipeline->{pipeline}{registry}{password});
			$registry_creds = <<EOF
            username: $pipeline->{pipeline}{registry}{username}
            password: "$registry_password_as_yaml"
EOF
		}
		print $OUT <<EOF;

  - name: update-genesis-assets
    plan:
    - in_parallel:
      - { get: git }
      - { get: kit-release, trigger: true }
      - { get: genesis-release }
    - task: list-kits
      config:
        platform: linux
        image_resource:
          type: registry-image
          source:
${registry_creds}
            repository: ${registry_prefix}$pipeline->{pipeline}{task}{image}
            tag:        $pipeline->{pipeline}{task}{version}
        inputs:
        - name: git
        params:
          GENESIS_KIT_NAME: (( concat pipeline.auto-update.kit "-genesis-kit" ))
        run:
          dir: $git_genesis_dir
          path: sh
          args:
          - -ce
          - |
            .genesis/bin/genesis list-kits \${GENESIS_KIT_NAME} -u
    - task: update-genesis
      config:
        platform: linux
        image_resource:
          type: registry-image
          source:
${registry_creds}
            repository: ${registry_prefix}$pipeline->{pipeline}{task}{image}
            tag:        $pipeline->{pipeline}{task}{version}
        inputs:
        - name: git
        - name: genesis-release
        outputs:
        - name: git
        params:
          CI_LABEL:         (( grab pipeline.auto-update.label || "concourse" ))
          GITHUB_USER:      (( grab pipeline.git.commits.user_name ))
          GITHUB_EMAIL:     (( grab pipeline.git.commits.user_email ))
        run:
          dir: git
          path: bash
          args:
          - -ce
          - |
            chmod +x ../genesis-release/genesis
            upstream="\$(../genesis-release/genesis -v 2>/dev/null | sed -e 's/Genesis v\\([^ ]*\\) .*/\\1/')"
            current="\$('${path_prefix}.genesis/bin/genesis' -v 2>/dev/null | sed -e 's/Genesis v\\([^ ]*\\) .*/\\1/')"
            if [[ -z "\$upstream" || ! "\$upstream" =~ ^[0-9]+(\.[0-9]+){2}(-rc[0-9]+)?\$ ]]; then
              echo >&2 "Error: could not get upstream genesis version"
              exit 1
            fi
            if [[ -z "\$current" || ! "\$current" =~ ^[0-9]+(\.[0-9]+){2}(-rc[0-9]+)?\$ ]]; then
              echo >&2 "Error: could not get embedded genesis version"
              exit 1
            fi
            if ../genesis-release/genesis ui-semver \$upstream ge \$current && \\
             ! ../genesis-release/genesis ui-semver \$current ge \$upstream ; then
              ../genesis-release/genesis$genesis_config_path embed
              if ! git diff --stat --exit-code '${path_prefix}.genesis/bin/genesis'; then
                git config --global user.email "\${GITHUB_EMAIL}"
                git config --global user.name "\${GITHUB_USER}"
                git add '${path_prefix}.genesis/bin/genesis'
                git commit -m "[\${CI_LABEL}] bump genesis to \$('$path_prefix.genesis/bin/genesis' version)$subdir_msg"
              fi
            fi
    - task: fetch-kit
      config:
        platform: linux
        image_resource:
          type: registry-image
          source:
${registry_creds}
            repository: ${registry_prefix}$pipeline->{pipeline}{task}{image}
            tag:        $pipeline->{pipeline}{task}{version}
        inputs:
        - name: git
        - name: kit-release
        outputs:
        - name: git
        params:
          KIT_VERSION_FILE:  (( grab pipeline.auto-update.file ))
          GENESIS_KIT_NAME:  (( grab pipeline.auto-update.kit ))
          CI_LABEL:          (( grab pipeline.auto-update.label || "concourse" ))
          GITHUB_AUTH_TOKEN: (( grab pipeline.auto-update.kit_auth_token || pipeline.auto-update.auth_token || "" ))
          GITHUB_USER:       (( grab pipeline.git.commits.user_name ))
          GITHUB_EMAIL:      (( grab pipeline.git.commits.user_email ))
        run:
          dir: git
          path: bash
          args:
          - -ce
          - |
            version="\$(cat ../kit-release/version)"
EOF
		print $OUT "            pushd '$pipeline->{pipeline}{git}{root}' &> /dev/null\n" unless $pipeline->{pipeline}{git}{root} eq '.';
		print $OUT <<EOF;
            if ! .genesis/bin/genesis --no-color list-kits \${GENESIS_KIT_NAME} | grep "v\$version\\\$"; then
              .genesis/bin/genesis fetch-kit \${GENESIS_KIT_NAME}/\$version
            fi
            sed -i'' "/^kit:/,/^  version:/{s/version.*/version: \$version/}" "\${KIT_VERSION_FILE}"
            if git diff --stat --exit-code '.genesis/kits' "\${KIT_VERSION_FILE}"; then
              echo "No change detected - still using \${GENESIS_KIT_NAME}/\$version$subdir_msg"
              exit 0
            fi
            git config --global user.email "\${GITHUB_EMAIL}"
            git config --global user.name "\${GITHUB_USER}"
            git add '.genesis/kits' "\${KIT_VERSION_FILE}"
EOF
		print $OUT "            popd &> /dev/null\n" unless $pipeline->{pipeline}{git}{root} eq '.';
		print $OUT <<EOF;
            git commit -m "[\${CI_LABEL}] bump kit \${GENESIS_KIT_NAME} to version \$version$subdir_msg"
    - put: git
      params:
        repository: git
        rebase: true
EOF
	} # }}}
	close $OUT;

	return run({ onfailure => 'Failed to merge Concourse pipeline definition', stderr => 0 },
		'spruce', 'merge', '--multi-doc', '--go-patch', '--prune', 'meta', '--prune', 'pipeline', "$dir/guts.yml", $pipeline->{file});
}

1;
