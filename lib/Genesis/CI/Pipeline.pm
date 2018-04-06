package Genesis::CI::Pipeline;

# FYI: we use quasi-JSON here, so we don't need to care about our indent level when consuming
#      the notification definitions
sub _gen_notifications {
	my ($pipeline, $message, $alias) = @_;
	$alias = "" unless defined $alias;
	my $notification = "aggregate: [\n";
	if ($pipeline->{pipeline}{slack}) {
		$notification .= <<EOF;
{
  put: "slack",
  params: {
    channel: "(( grab pipeline.slack.channel ))",
    username: "(( grab pipeline.slack.username ))",
    icon_url: "(( grab pipeline.slack.icon ))",
    text: '(( concat pipeline.name ": $message" ))'
  }
},
EOF
	}
	if ($pipeline->{pipeline}{hipchat}) {
		$notification .= <<EOF;
{
  put: "hipchat",
  params: {
    from: "(( grab pipeline.hipchat.username ))",
    color: "gray",
    message: '(( concat pipeline.name ": $message" ))',
    notify: "(( grab pipeline.hipchat.notify ))"
  }
},
EOF
	}
	if ($pipeline->{pipeline}{stride}) {
		$notification .= <<EOF;
{
  put: "stride",
  params: {
    conversation: "(( grab pipeline.stride.conversation ))",
    message: '(( concat pipeline.name ": $message" ))'
  }
},
EOF
	}
	if ($pipeline->{pipeline}{email}) {
		$notification .= <<EOF;
{
  do: [
  { get: build-email-$alias },
  { task: write-email-body,
    config: {
      platform: linux,
      image_resource: {
        type: docker-image,
        source: {
          repository: ubuntu,
        },
      },

      inputs: [
        { name: build-email-$alias },
        { name: out },
      ],
      outputs: [
        { name: email },
      ],

      run: {
        path: build-email-$alias/run,
        args: [],
      },
    },
  },

  { put: email,
    params: {
      body:    email/body,
      headers: email/header,
      subject: email/subject,
    },
  }]
}
EOF
	}
	$notification .= "]";
	return $notification;
}

sub read {
	my ($class, $file) = @_;

	my @errors = ();
	my $p = load_yaml(spruce_merge($file));
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
			unless m/^(name|public|tagged|errands|vault|git|slack|hipchat|stride|email|boshes|task|layout|layouts|debug|stemcells|skip_upkeep|locker|unredacted)$/;
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
				unless m/^(url|role|secret|verify)$/;
		}
	}

	# validate pipeline.git.*
	if (ref($p->{pipeline}{git}) ne 'HASH') {
		push @errors, "`pipeline.git' must be a map.";
	} else {
		# required subkeys
		for (qw(owner repo private_key)) {
			push @errors, "`pipeline.git.$_' is required."
				unless $p->{pipeline}{git}{$_};
		}
		# allowed subkeys
		for (keys %{$p->{pipeline}{git}}) {
			push @errors, "Unrecognized `pipeline.git.$_' key found."
				unless m/^(host|owner|repo|private_key)$/;
		}
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
			# FIXME: fully implement and test email notifications
			push @errors, "Email notifications are not fully implemented yet.";
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

	# validate (optional) pipeline.task.*
	if (exists $p->{pipeline}{task}) {
		if (ref($p->{pipeline}{task}) eq 'HASH') {
			# allowed subkeys
			for (keys %{$p->{pipeline}{task}}) {
				push @errors, "Unrecognized `pipeline.task.$_' key found."
					unless m/^(image|version)$/;
			}
		} else {
			push @errors, "`pipeline.task' must be a map.";
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
			# required sub-subkeys
			if (is_create_env($env)) {
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
						unless m/^(stemcells|url|ca_cert|username|password|alias)$/;
				}
			}
		}
	}

	return $p, @errors;
}

sub parse {
	my ($class, $file, $layout) = @_;
	$layout ||= 'default';

	my ($pipeline, @errors) = $class->read($file);
	if (@errors) {
		error "#R{ERRORS encountered} in pipeline definition in #Y{$file}:";
		error "  - #R{$_}" for @errors;
		exit 1;
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

	# some default values, if the user didn't supply any
	$P->{pipeline}{vault}{role}   ||= "";
	$P->{pipeline}{vault}{secret} ||= "";
	$P->{pipeline}{vault}{verify} = yaml_bool($P->{pipeline}{vault}{verify}, 1);

	$P->{pipeline}{task}{image}   ||= 'starkandwayne/concourse';
	$P->{pipeline}{task}{version} ||= 'latest';

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
	$P->{aliases} = { map { $_ => ($P->{pipeline}{boshes}{$_}{alias} || $_) } keys %envs};

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

	return bless($P, $class);
}

sub _tree {
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

sub as_tree {
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
		_tree("", $_, \%trees);
		print "\n";
	}
}

sub as_graphviz {
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

sub as_concourse {
	my ($self) = @_;
	my $pipeline = $self;

	my $dir = workdir;
	open my $OUT, ">", "$dir/guts.yml"
		or die "Failed to generate Concourse Pipeline YAML configuration: $!\n";

	# Figure out what environments auto-trigger, and what don't
	my %auto = map { $_ => 1 } @{$pipeline->{auto}};

	# CONCOURSE: pipeline (+params) {{{
	print $OUT <<'EOF';
---
pipeline:
  git:
    user:        git
    host:        github.com
    uri:         (( concat pipeline.git.user "@" pipeline.git.host ":" pipeline.git.owner "/" pipeline.git.repo ))
    owner:       (( param "Please specify the name of the user / organization that owns the Git repository" ))
    repo:        (( param "Please specify the name of the Git repository" ))
    branch:      master
    private_key: (( param "Please generate an SSH Deployment Key and install it into Github (with write privileges)" ))

EOF

	if ($pipeline->{pipeline}{slack}) {
		print $OUT <<'EOF';
  slack:
    webhook:  (( param "Please provide a Slack Integration WebHook." ))
    channel:  (( param "Please specify the channel (#name) or user (@user) to send messages to." ))
    username: runwaybot
    icon:     http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png
EOF
	}
	if ($pipeline->{pipeline}{hipchat}) {
		print $OUT <<'EOF';
  hipchat:
    url:      http://api.hipchat.com
    room_id:  (( param "Please specify the room ID that Concourse should send HipChat notifications to" ))
    token:    (( param "Please specify the HipChat authentication token" ))
    notify:   false
    username: runwaybot
EOF
	}
	if ($pipeline->{pipeline}{stride}) {
		print $OUT <<'EOF';
  stride:
    client_id: (( param "Please specify the client ID for the Stride app that Concourse should send notifications as" ))
    client_secret: (( param "Please specify the client secret for the Stride app that Concourse should send notifications as" ))
    cloud_id: (( param "Please specify the Stride cloud ID that Concourse should send notifications to" ))
    conversation: (( param "Please specify the Stride conversation name that Concourse should send notifications to" ))
EOF
	}
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
	}
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
	}
	# }}}
	# CONCOURSE: groups, and resource configuration {{{
	print $OUT <<EOF;
groups:
  - name: $pipeline->{pipeline}{name}
    jobs:
EOF
	print $OUT "    - $_\n" for sort map { "$pipeline->{aliases}{$_}-" . deployment_suffix } @{$pipeline->{envs}};
	print $OUT "    - notify-$_-changes\n" for sort map { "$pipeline->{aliases}{$_}-" . deployment_suffix }
		grep { ! $auto{$_} } @{$pipeline->{envs}};

	print $OUT <<EOF;

resources:
  - name: git
    type: git
    source:
      branch:      (( grab pipeline.git.branch ))
      private_key: (( grab pipeline.git.private_key ))
      uri:         (( grab pipeline.git.uri ))
EOF
   # }}}
	# CONCOURSE: env-specific resource configuration {{{
	for my $env (sort @{$pipeline->{envs}}) {
		# YAML snippets, to make the print's less obnoxious {{{
		#
		# 1) do we tag the jobs so that they are constrained to a
		#   specific subset of concourse workers? ('tagged' directive)
		my $tag_yaml = $pipeline->{pipeline}{tagged} ? "tags: [$env]" : "";

		my $alias = $pipeline->{aliases}{$env};
		print $OUT <<EOF;
  - name: ${alias}-changes
    type: git
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
			my ($pre, @unique) = unique_suffix($trigger, $env);
			$pre = "$pre-" unless $pre eq "";
			for (map { "$pre$_" } expand_tokens(@unique)) {
				print $OUT <<EOF;
        - ${_}.yml
EOF
			}
			print $OUT <<EOF;

  - name: ${alias}-cache
    type: git
    source:
      .: (( inject resources.git.source ))
      paths:
        - .genesis/bin/genesis
        - .genesis/kits
        - .genesis/config
EOF
			print $OUT "# $trigger -> $env\n";
			for (expand_tokens(common_base($env, $trigger))) {
				print $OUT <<EOF;
        - .genesis/cached/${trigger}/${_}.yml
EOF
			}
		} else {
			print $OUT <<EOF;
        - .genesis/bin/genesis
        - .genesis/kits
        - .genesis/config
EOF
			for (expand_tokens(split /-/, $env)) {
				print $OUT <<EOF;
        - ${_}.yml
EOF
			}
		}
		unless (is_create_env($env)) {
			print $OUT <<EOF;

  - name: ${alias}-cloud-config
    type: bosh-config
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

  - name: ${alias}-runtime-config
    type: bosh-config
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

EOF
		}
		if ($pipeline->{pipeline}{locker}{url}) {
			my $deployment_suffix = deployment_suffix;
			unless (is_create_env($env)) {
				my $bosh_lock = $env;
				if ($pipeline->{pipeline}{boshes}{$env}{url} && $pipeline->{pipeline}{boshes}{$env}{url} =~ m|https?://(.*)?:(.*)|) {
					my $addr = gethostbyname($1);
					$bosh_lock = inet_ntoa($addr) . ":" . $2;
				}

				# <alias>-bosh-lock is used to prevent the parent bosh from upgrading while we deploy
				# - not necessary for create-env
				print $OUT <<EOF;
  - name: ${alias}-bosh-lock
    type: locker
    $tag_yaml
    source:
      locker_uri: (( grab pipeline.locker.url ))
      username: (( grab pipeline.locker.username ))
      password: (( grab pipeline.locker.password ))
      skip_ssl_validation: (( grab pipeline.locker.skip_ssl_validation ))
      ca_cert: (( grab pipeline.locker.ca_cert ))
      bosh_lock: $pipeline->{pipeline}{boshes}{$env}{url}
EOF
			}
			print $OUT <<EOF;
  - name: ${alias}-deployment-lock
    type: locker
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
    source:
      url: (( grab pipeline.slack.webhook ))

EOF
	}
	if ($pipeline->{pipeline}{hipchat}) {
		print $OUT <<'EOF';
  - name: hipchat
    type: hipchat-notification
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
    source:
      client_id: (( grab pipeline.stride.client_id ))
      client_secret: (( grab pipeline.stride.client_secret ))
      cloud_id: (( grab pipeline.stride.cloud_id ))
EOF
	}
	if ($pipeline->{pipeline}{email}) {
		print $OUT <<'EOF';
  - name: build-email-changes-staged
    type: script
    source:
      filename: run
      body: |
        #!/bin/bash
        mkdir -p email
        rm -rf email/*
        echo "X-Concourse-Site-Env: ${CI_SITE_ENV}" >>email/header
        head -n1 out/notif > email/subject
        sed -e 's/\`\`\`//' out/notif > email/body
  - name: build-email-success
    .: (( inject resources.build-email-changes-staged ))
  - name: build-email-failure
    .: (( inject resources.build-email-changes-staged ))

  - name: email
    type: email
    source:
      to:   (( grab pipeline.email.to ))
      from: (( grab pipeline.email.from ))
      smtp:
        host:     (( grab pipeline.email.smtp.host ))
        port:     (( grab pipeline.email.smtp.port ))
        username: (( grab pipeline.email.smtp.username ))
        password: (( grab pipeline.email.smtp.password ))
EOF
	}
	# }}}
	# CONCOURSE: resource types {{{
	print $OUT <<'EOF';
resource_types:
  - name: script
    type: docker-image
    source:
      repository: cfcommunity/script-resource

  - name: email
    type: docker-image
    source:
      repository: pcfseceng/email-resource

  - name: slack-notification
    type: docker-image
    source:
      repository: cfcommunity/slack-notification-resource

  - name: hipchat-notification
    type: docker-image
    source:
      repository: cfcommunity/hipchat-notification-resource

  - name: stride-notification
    type: docker-image
    source:
      repository: starkandwayne/stride-notification-resource

  - name: bosh-config
    type: docker-image
    source:
      repository: cfcommunity/bosh-config-resource

  - name: locker
    type: docker-image
    source:
      repository: cfcommunity/locker-resource

EOF
	# }}}
	print $OUT <<EOF;
jobs:
EOF
	for my $env (sort @{$pipeline->{envs}}) {
		# CONCOURSE: env-specific job configuration {{{

		# YAML snippets, to make the print's less obnoxious {{{
		#
		# 1) do we tag the jobs so that they are constrained to a
		#   specific subset of concourse workers? ('tagged' directive)
		my $tag_yaml = $pipeline->{pipeline}{tagged} ? "tags: [$env]" : "";

		# 2) Are we auto-triggering this environment?
		my $trigger = $auto{$env} ? "true" : "false";

		# 3) what is our deployment suffix?
		my $deployment_suffix = deployment_suffix;

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
			if ($trigger eq "true") {
				$cache_yaml = "- { get: $alias-cache, passed: [$passed_alias], trigger: true }";
			} else {
				$cache_yaml = "- { get: $alias-cache, passed: [notify-$alias-$deployment_suffix-changes], trigger: false }";
			}
		}
		my $notify_cache = $pipeline->{triggers}{$env} ?
			"- { get: $alias-cache, passed: [$passed_alias], trigger: true }" : "";

		# 7) If we don't auto-trigger, we should use passed as our notify resource
		#    otherwise, use the live value
        my $changes_yaml = $trigger eq "true" ?
			"- { get: $alias-changes, trigger: true }" :
			"- { get: $alias-changes, trigger: false, passed: [notify-$alias-$deployment_suffix-changes]}";

		# 8) Build notifications for non-automatic deployments that sense changes
		my $changes_staged_notification = _gen_notifications($pipeline,
			"Changes are staged to be deployed to $env-$deployment_suffix, " .
			"please schedule + run a deploy via Concourse", "changes-staged");

		# 9) Build notifications for failed deployments
		my $deployment_failure_notification = _gen_notifications($pipeline,
			"Concourse deployment to $env-$deployment_suffix failed", "failure");

		# 10) Build notifications for successful deployments
		my $deployment_success_notification = _gen_notifications($pipeline,
			"Concourse successfully deployed $env-$deployment_suffix", "success");

		# 11) directory to find the genesis binary in (use previous env cache if present, else local-changes
		my $genesis_bindir = $passed ? "$alias-cache" : "$alias-changes";

		# }}}

		if ($trigger eq "false" ) {
			# notify job for non-automatic deploys {{{
			print $OUT <<EOF;
  - name: notify-$alias-$deployment_suffix-changes
    public: true
    serial: true
    plan:
    - aggregate:
      - { get: $alias-changes, trigger: true }
EOF
			unless (is_create_env($env)) {
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
      $notify_cache
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
			unless (is_create_env($env)) {
				# <alias>-bosh-lock is used to prevent the parent bosh from upgrading while we deploy
				# - not necessary for create-env
				print $OUT <<EOF;
        - put: ${alias}-bosh-lock
          $tag_yaml
          params:
            lock_op: unlock
            key: dont-upgrade-bosh-on-me
            locked_by: ${alias}-${deployment_suffix}
EOF
			}
			print $OUT <<EOF;
        - put: ${alias}-deployment-lock
          $tag_yaml
          params:
            lock_op: unlock
            key: i-need-to-deploy-myself
            locked_by: ${alias}-${deployment_suffix}
EOF
		}
		print $OUT <<EOF;
      do:
EOF
		if ($pipeline->{pipeline}{locker}{url}) {
			unless (is_create_env($env)) {
				# <alias>-bosh-lock is used to prevent the parent bosh from upgrading while we deploy
				# - not necessary for create-env
				print $OUT <<EOF;
      - put: ${alias}-bosh-lock
        $tag_yaml
        params:
          lock_op: lock
          key: dont-upgrade-bosh-on-me
          locked_by: ${alias}-${deployment_suffix}
EOF
			}
			print $OUT <<EOF;
      - put: ${alias}-deployment-lock
        $tag_yaml
        params:
          lock_op: lock
          key: i-need-to-deploy-myself
          locked_by: ${alias}-${deployment_suffix}
EOF
		}
		print $OUT <<EOF;
      - aggregate:
EOF
		# only add cloud/runtime config on true-triggers, otherwise it goes in notifications
		# also make sure that we are not deploying with create-env (no cloud/runtime config for that scenario)
		if (! is_create_env($env) && $trigger eq "true") {
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
            type: docker-image
            source:
              repository: $pipeline->{pipeline}{task}{image}
              tag:        $pipeline->{pipeline}{task}{version}
          params:
            CI_NO_REDACT:         $pipeline->{pipeline}{unredacted}
            CURRENT_ENV:          $env
            PREVIOUS_ENV:         $passed
            CACHE_DIR:            $alias-cache
            GIT_BRANCH:           (( grab pipeline.git.branch ))
            GIT_PRIVATE_KEY:      (( grab pipeline.git.private_key ))
            VAULT_ROLE_ID:        $pipeline->{pipeline}{vault}{role}
            VAULT_SECRET_ID:      $pipeline->{pipeline}{vault}{secret}
            VAULT_ADDR:           $pipeline->{pipeline}{vault}{url}
            VAULT_SKIP_VERIFY:    ${\(!$pipeline->{pipeline}{vault}{verify})}
            BOSH_NON_INTERACTIVE: true
EOF
		# don't supply bosh creds if we're create-env, because no one to talk to
		unless (is_create_env($env)) {
			print $OUT <<EOF;
            BOSH_ENVIRONMENT:     $pipeline->{pipeline}{boshes}{$env}{url}
            BOSH_CA_CERT: |
EOF
			for (split /\n/, $pipeline->{pipeline}{boshes}{$env}{ca_cert}) {
				print $OUT <<EOF;
              $_
EOF
			}
			print $OUT <<EOF;
            BOSH_CLIENT:        $pipeline->{pipeline}{boshes}{$env}{username}
            BOSH_CLIENT_SECRET: $pipeline->{pipeline}{boshes}{$env}{password}
EOF
		}
		print $OUT <<EOF if $pipeline->{pipeline}{debug};
            DEBUG:              $pipeline->{pipeline}{debug}
EOF
		print $OUT <<EOF;
            WORKING_DIR:        $alias-changes # work out of latest changes for this environment
            OUT_DIR:            out/git


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

		# CONCOURSE: run optional errands as tasks - non-create-env only (otherwise no bosh to run the errand) {{{
		unless (is_create_env($env)) {
			for my $errand_name (@{$pipeline->{pipeline}{errands}}) {
				print $OUT <<EOF;
        # run errands against the deployment
      - task: $errand_name-errand
        $tag_yaml
        config:
          platform: linux
          image_resource:
            type: docker-image
            source:
              repository: $pipeline->{pipeline}{task}{image}
              tag:        $pipeline->{pipeline}{task}{version}
          params:
            CI_NO_REDACT:       $pipeline->{pipeline}{unredacted}
            CURRENT_ENV:        $env
            ERRAND_NAME:        $errand_name

            BOSH_ENVIRONMENT:   $pipeline->{pipeline}{boshes}{$env}{url}
            BOSH_CA_CERT: |
EOF
			for (split /\n/, $pipeline->{pipeline}{boshes}{$env}{ca_cert}) {
				print $OUT <<EOF;
              $_
EOF
			}
			print $OUT <<EOF;
            BOSH_CLIENT:        $pipeline->{pipeline}{boshes}{$env}{username}
            BOSH_CLIENT:        $pipeline->{pipeline}{boshes}{$env}{username}
            BOSH_CLIENT_SECRET: $pipeline->{pipeline}{boshes}{$env}{password}
EOF
			print $OUT <<EOF if $pipeline->{pipeline}{debug};
            DEBUG:              $pipeline->{pipeline}{debug}
EOF
			print $OUT <<EOF;

          run:
            path: ../../$genesis_bindir/.genesis/bin/genesis
            dir:  out/git
            args: [ci-pipeline-run-errand]
          inputs:
            - name: out
            - name: $genesis_bindir
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
          - { name: $genesis_bindir }
          outputs:
          - { name: cache-out }
          run:
            path: $genesis_bindir/.genesis/bin/genesis
            args: [ci-generate-cache]
          params:
            CI_NO_REDACT:    $pipeline->{pipeline}{unredacted}
            CURRENT_ENV:     $env
            WORKING_DIR:     out/git
            OUT_DIR:         cache-out/git
            GIT_BRANCH:      (( grab pipeline.git.branch ))
            GIT_PRIVATE_KEY: (( grab pipeline.git.private_key ))
EOF

		print $OUT <<EOF if $pipeline->{pipeline}{debug};
            DEBUG:       $pipeline->{pipeline}{debug}
EOF
		print $OUT <<EOF;
          platform: linux
          image_resource:
            type: docker-image
            source:
              repository: $pipeline->{pipeline}{task}{image}
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
	close $OUT;

	return spruce_merge({ prune => [qw(meta pipeline)] },
		"$dir/guts.yml", $pipeline->{file});
}

1;
