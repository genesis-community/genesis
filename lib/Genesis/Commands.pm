package Genesis::Commands;

# TODO: Should this be a class with a registry of command objects?
# - define_command becomes new that adds the new command object to the class's
#   internal list of registered clommands
# - prepare_command changes to class method select to return sets the selected
#   command and register it as the selected command, and then add an instance
#   method for prepare.
# - commands becomes class method list
# - current_command becomes class method current
# - has_command becomes class method exists
# - everything else becomes an instant method (renaming to drop _command)
#
# Will explore once this is working.

use strict;
use warnings;

use base 'Exporter';
our @EXPORT = qw/
	commands
	define_command
	prepare_command
	set_top_path
	build_command_environment
	current_command
	current_command_alias
	known_commands
	run_command
	has_command
	equivalent_commands
	command_help
	command_usage
	command_properties
	get_options
	has_option
	option_defaults
	append_options
	has_scope
	check_embedded_genesis
	check_prereqs
	at_exit
/;

# Core Modules
use Getopt::Long qw/GetOptionsFromArray/;
use File::Basename qw/dirname basename/;
use Cwd qw/getcwd abs_path/;

use Genesis;
use Genesis::State;
use Genesis::Term qw/wrap terminal_width csprintf decolorize csize/;
use Genesis::Log;

our ($COMMAND, $CALLED, %RUN, %PROPS, %GENESIS_COMMANDS, @COMMANDS, @COMMAND_ARGS);
our $COMMAND_OPTIONS = {};
our $END_HOOKS = [];

use constant { # {{{
	# Functional Areas (and Submodule)
	# Used for help generation, and default command module identifier
	ENVIRONMENT => {order =>  0, module => "Env",        label => "Environment Management"},
	INFO        => {order =>  1, module => "Info",       label => "Informative"},
	REPOSITORY  => {order =>  2, module => "Repo",       label => "Repository Management"},
	KIT         => {order =>  3, module => "Kit",        label => "Kit Management"},
	PIPELINE    => {order =>  4, module => "Pipelines",  label => "Pipeline Management"},
	GENESIS     => {order =>  5, module => "Core",       label => "Genesis Management"},
	UTILITY     => {order => -1, module => "Utility",    label => "Script Callback Helper"},
	DEPRECATED  => {order => -2, module => "Deprecated", label => "Deprecated"},

	# Option Groups
	BLANK_OPTIONS => 0,
	BASE_OPTIONS  => 1,
	REPO_OPTIONS  => 2,
	ENV_OPTIONS   => 3
}; # }}}

our @global_options = ( # {{{
	[
		"help|h" =>
			"Show this help screen.",
	],
	[
		"color!" =>
			"Enable [or disable] color output",

		'log|L=s' =>
			"Set the log level.  Valid values are NONE, ERROR, WARN, DEBUG, INFO, ".
			"and TRACE.  Default is WARN",

		"quiet|q" =>
			"Suppress informative output (errors will still be displayed)",

		"debug|D" =>
			"Enable debugging, printing helpful message about what Genesis is doing, ".
			"to standard error.\n\n".
			"Deprecated; use --log=DEBUG instead.",

		"trace|T" =>
			"Deeper level of debugging.  Any trace commands within the Genesis ".
			"codebase will be printed, along with identifying the line they were ".
			"encountered.\n\n".
			"Deprecated; use --log=TRACE instead.",

		"show-stack|S+" =>
			"Will show stack trace when displaying any log messages.  Specifying it ".
			"twice will show only the current line, while specifying it once will ".
			"show the whole stack.",
	],
	[
	  "cwd|C=s" =>
			"Effective working directory.  You can also specify the environment YAML ".
			"file to use, in which case the working directory is the one containing ".
			"the specified file.  Defaults to '.'"
	],
	[
		"bosh-env|e=s" =>
			"Which BOSH environment (aka director) to use.  If not specified, it ".
			"will use the value in genesis.bosh or genesis.env in that order.  Can ".
			"also be provided using either \$GENESIS_BOSH_ENVIRONMENT env variables.".
			"\n".
			"As of v2.8.0, the BOSH director information is read from Exodus data ".
			"instead of the local .bosh/config, and as such, expect the deployment ".
			"type of the bosh director to be 'bosh'.  If this is not the case, you ".
			"can specify the deployment type after the deployment name, separated ".
			"by a '/' (ie c-aws-myenv/new-bosh).  This will inform the system where ".
			"to find the Exodus data.",

		"config|c=s@" =>
			"Specify a YAML file to be used as a config instead of fetching it from ".
			"the BOSH director.  This option can be specified multiple times for ".
			"different configurations.  The syntax for specifying the config is:".
			"\n".
			"[<type>[@<name>]=]<path>".
			"\n".
			"The type defaults to 'cloud', and name defaults to 'default' if not ".
			"given.  In this way, it maintains its backwards compatibility of the ".
			"original #y{-c} option for specifying the cloud config file.",

		"cpi=s" =>
			"Specify the CPI explicitly.  Normally, this is determined from the BOSH ".
			"director, but can be specified using this option if the BOSH director ".
			"is not available."

	]
); # }}}

sub define_command { # {{{
	my ($name, $props, $fn);
	$name = shift;
	$props = ref($_[0]) eq 'HASH' ? shift : {};
	$fn = scalar(@_) ? shift : undef;

	my $default_props = {
		scope              => 'any',
		no_vault           => 0,
		function_group     => GENESIS,
		option_group       => BASE_OPTIONS,
		option_passthrough => 0
	};

	$PROPS{$name} = {%$default_props, %$props};
	my $fn_require = '';
	if (ref($fn) ne "CODE") {
		if (defined($fn)) {
			$fn =~ m/(.*)::[^:]*$/;
			$fn_require = $1;
		} else {
			my ($fn_label, $fn_submodule) = @{($PROPS{$name}{function_group})}{qw(label module)};
			(my $fn_name = $name) =~ s/-/_/g;
			$fn_submodule ||= $fn_label;
			$fn_require = "Genesis::Commands::$fn_submodule";
			$fn = $fn_require.'::'.$fn_name;
		}
		$fn_require =~ s/::/\//g;
		$fn_require =~ s/(\.pm)?$/.pm/;
	}

	$RUN{$name} = sub {
		$ENV{GENESIS_COMMAND} = $name;
		$ENV{GENESIS_NO_VAULT} = 1 if $PROPS{$name}{no_vault};
		if ($fn_require) {
			require $fn_require;
			$fn = \&{$fn};
		}
		$fn->(@_);
	};
	push @COMMANDS, $name;
	$GENESIS_COMMANDS{$name} = $name;
	$GENESIS_COMMANDS{$_} = $name for @{$PROPS{$name}{aliases} || (defined($PROPS{$name}{alias}) ? [$PROPS{$name}{alias}] : [])};
	return;
} # }}}

sub commands { # {{{
	return (@COMMANDS);
} # }}}

sub current_command { # {{{
	return $COMMAND;
} # }}}

sub current_command_alias { # {{{
	return $CALLED;
} # }}}

sub known_commands { # list the known genesis commands specified by define_command {{{
	return grep {$_ eq $GENESIS_COMMANDS{$_}} keys %GENESIS_COMMANDS;
} # }}}

sub prepare_command { # {{{
	($CALLED, my @args) = @_;
	$COMMAND = $GENESIS_COMMANDS{$CALLED};
	trace "Preparing genesis command '$COMMAND'".($CALLED ne $COMMAND ? ' (called as $CALLED)':'');
	parse_options(\@args);
	set_logging_state();
} # }}}

sub run_command { # {{{
	command_help("Unrecognized command '$CALLED'")
		unless defined($RUN{$COMMAND});
	if (defined(command_properties()->{deprecated})) {
		my $msg =
			"The #G{$COMMAND} command has been deprecated, and will be ".
			"removed in a future version of Genesis.";
		if (my $replacement = command_properties()->{deprecated}) {
			$msg .= "  It has been replaced by #G{$replacement}"
		}
		warning({label => "DEPRECATED"}, $msg);
	}
	$RUN{$COMMAND}(@COMMAND_ARGS);
	exit 0
} # }}}

sub has_command { # {{{
	my $cmd = shift;
	return defined($GENESIS_COMMANDS{$cmd});
} # }}}

sub equivalent_commands { # {{{
	my ($cmd1,$cmd2) = @_;
	return $GENESIS_COMMANDS{$cmd1}//'' eq $GENESIS_COMMANDS{$cmd2}//'';
} # }}}

sub command_properties { # {{{
	my $cmd = $GENESIS_COMMANDS{$_[0]||''} || $COMMAND;
	bug "No active or given command -- cannot return command_properties"
		unless $cmd;

	return $PROPS{$cmd};
} # }}}

sub parse_options { # {{{

	my $args = shift;
	my $args_copy = [@$args];
	my @base_spec = keys %{({map {@$_} @global_options[0..$PROPS{$COMMAND}{option_group}]})};

	my @opts_spec = (
		keys %{{ @{$PROPS{$COMMAND}{options} || []} }},
		grep {/^[^\^]/} keys %{{ @{$PROPS{$COMMAND}{deprecated_options} || []} }} #ignore deprecated option references
	);
	trace "Supported Options:".join("\n  ",(''),@base_spec,@opts_spec);

	# Workaround - genesis helper always injects -C option, but many commands
	# don't use -C (not repo/env scoped)  Inject it and ignore it for those with
	# option_group < Genesis::Commands::REPO_OPTIONS
	push @base_spec, "no_cwd|cwd|C=s" if $PROPS{$COMMAND}{option_group} < Genesis::Commands::REPO_OPTIONS;

	# Clean out any special formatting noise
	@opts_spec = map {$_ =~ s/^~//r} grep {$_ ne '-section-break-'} @opts_spec;

	$COMMAND_OPTIONS->{color} = 1 unless exists $COMMAND_OPTIONS->{color};

	Getopt::Long::Configure(
		qw(no_ignore_case bundling),
		$PROPS{$COMMAND}{option_passthrough}
		? qw(pass_through no_auto_abbrev)
		: qw(no_pass_through auto_abbrev),
		$PROPS{$COMMAND}{option_require_order} ? 'require_order' : 'permute'
	);

	my $parsing_ok = 1;
	my @option_warnings = ();
	{
		local $SIG{__WARN__} = sub { push @option_warnings, @_; };
		$parsing_ok = GetOptionsFromArray($args, $COMMAND_OPTIONS, (@base_spec,@opts_spec));
	}

	unless ($parsing_ok) {
		set_logging_state();
		debug(
			"[[Option Parsing Warning: >>%s",
			join("", @option_warnings)
		);
		command_usage(1, join("\n", map {chomp; $_} @option_warnings) || "Error parsing options");
	}

	shift @$args if ($args->[0]||'') eq '--';
	@COMMAND_ARGS = (@$args);

	# Extract Core options
	$ENV{NOCOLOR}        = 'y' if !delete($COMMAND_OPTIONS->{color});
	$ENV{QUIET}          = 'y' if  delete($COMMAND_OPTIONS->{quiet});

	# Remove workaround options
	dump_var 'Received Options' => $COMMAND_OPTIONS;
	delete($COMMAND_OPTIONS->{no_cwd});
	dump_var 'Received Arguments' => \@COMMAND_ARGS;
	return;
} # }}}

sub get_options { # {{{
	return $COMMAND_OPTIONS unless scalar(@_);
	my %slice;
	for (@_) {
		if (exists($COMMAND_OPTIONS->{$_})) {
			$slice{$_} = $COMMAND_OPTIONS->{$_};
		} elsif ($_ =~ '_') {
			my $__ = _u2d($_);
			$slice{$_} = $COMMAND_OPTIONS->{$__} if exists($COMMAND_OPTIONS->{$__});
		}
	}
	return \%slice
} # }}}

sub has_option { # {{{
	my ($option,$test) = @_;
	return 0 unless defined($COMMAND_OPTIONS->{$option});
	return 1 unless defined($test);
	if (ref($test) eq "Regexp") {
		return $COMMAND_OPTIONS->{$option} =~ $test ? 1 : 0;
	} else {
		return $COMMAND_OPTIONS->{$option} eq $test ? 1 : 0;
	}
} # }}}

sub option_defaults { # {{{
	while (@_) {
		(my $k, my $v, @_) = @_;
		next if defined($COMMAND_OPTIONS->{$k});
		$COMMAND_OPTIONS->{$k} = $v;
	}
} # }}}

sub append_options { # {{{
	my %extra_options = @_;
	$COMMAND_OPTIONS->{$_} = $extra_options{$_} for (keys %extra_options);
	return $COMMAND_OPTIONS;
} # }}}

sub command_help { # {{{
	my ($msg, $rc) = @_;
	$rc = $msg ? 1 : 0 unless defined($rc);
	$msg ||= ''; # TODO: a summary blurb about genesis

	my $hr = "#${\($rc ? 'r' : 'K')}\{" . ("=" x terminal_width) ."}";
	my $bc = $Genesis::BUILD =~ /\+\)/ ? 'R' : 'G';
	my $ver = "#gi{genesis v$Genesis::VERSION}#${bc}i{$Genesis::BUILD}\n";

	# TODO: use named colors that are dark/light aware.

	info "$hr\n";

	if ($rc) {
		fatal {show_stack => 'default'}, "$msg\n"
	}

	my $out =
		wrap(
			"#g{${\(humanize_bin)}} [<global options...>] #G{<command>} [<command options and args...>]"
			,terminal_width,"#Wku{Usage:} ", 7
		)."\n".
		"\n".
		wrap(
			"The following Genesis commands are grouped by function areas, and marked ".
			"by the context they run against.  Some commands can run against multiple ".
			"contexts; see the help (-h) for the command for how to use it in the".
			"different contexts.", terminal_width
		)."\n".
		"\n";

	my @commands = grep {defined($PROPS{$_}) && $PROPS{$_}{function_group}{order} >= 0} (commands);
	push @commands, (grep {defined($PROPS{$_}) && $PROPS{$_}{function_group}{order} < 0} (commands))
		if get_options->{all};

	my %function_groups;
	$function_groups{$_->{order} < 0 ? 100 - $_->{order} : $_->{order}} = $_->{label} || $_->{module} for (
		map {$PROPS{$_}{function_group}}
		@commands
	);

	my $cmd_width = (sort {$b <=> $a} map {length($_)} @commands)[0];

	my %applicable_scopes = (
		env => { o => 1, c => "M", i => "E",
			d => "Targets a Genesis environment file (with or without .yml suffix)"},
		repo => { o => 2, c => "g", i => "R",
			d => "Must be run in a Genesis Environment repository, or use -C to target one.", },
		kit => { o => 3, c => "C", i => "K",
			d => "Must be run in a Genesis Kit repository.", },
		empty => { o => 4,c => "y", i => "N",
			d => "Cannot be run in an existing Genesis Environment or Kit repository.", },
		pipeline => { o => 5, c => "R", i => "P",
			d => "Can only be run in a Genesis pipeline by task running on a Concourse worker.", }
	);
	my @scopes = (sort {$applicable_scopes{$a}{o} <=> $applicable_scopes{$b}{o}} keys %applicable_scopes);
	my $scope_width = scalar(@scopes);
	my $cont_prefix = "#-k{".(' ' x $scope_width)."}";
	$out .= "#ui{Context:}\n";
	for my $scope (@scopes) {
		my $label = "#-k{" . (' ' x ($applicable_scopes{$scope}{o} - 1)) . "}";
		$label .=   "#$applicable_scopes{$scope}{c}k{$applicable_scopes{$scope}{i}}";
		$label .=   "#-k{" . (' ' x (5 - $applicable_scopes{$scope}{o})) . "} ";
		$out .= wrap(
			"#i{$applicable_scopes{$scope}{d}}",
			terminal_width, $label, $scope_width + 1, $cont_prefix
		)."\n";
	}

	for my $order (sort {$a <=> $b} keys %function_groups) {
		my $section = $function_groups{$order};
		$section .= ' ' x (terminal_width() - length($section));
		$out .= "\n#Wku{$section}\n";
		my $fixed_order = $order > 100 ? -($order - 100) : $order;
		for my $cmd (grep {$PROPS{$_}{function_group}{order} == $fixed_order} @commands) {
			my $scope_filter = $PROPS{$cmd}{scope};
			$scope_filter = [$scope_filter] unless ref($scope_filter) eq 'ARRAY';
			my @cmd_scopes = sort map {ref($_) eq 'ARRAY' ? (ref($_->[1]) eq 'ARRAY' ? @{$_->[1]} : ($_->[1])) :($_)} @${scope_filter};
			my $label = '';
			for my $scope (@scopes) {
				my $icon = "#$applicable_scopes{$scope}{c}k{ }";
				$icon = "#$applicable_scopes{$scope}{c}k{$applicable_scopes{$scope}{i}}"
					if (scalar(grep {$_ eq 'any'} @cmd_scopes ) && $scope ne 'pipeline')
					|| (scalar(grep {$scope eq $_} @cmd_scopes) && $applicable_scopes{$scope}{i});
				$label .= $icon;
			}
			$label .= " #G{$cmd}  ";
			my $summary = ($PROPS{$cmd}{summary} || '-- no summary provided -- ');
			if ($PROPS{$cmd}{alias} || $PROPS{$cmd}{aliases}) {
				my @aliases = grep {defined($_)} ($PROPS{$cmd}{alias}, @{$PROPS{$cmd}{aliases}||[]});
				$summary .= " #G{(alias".(@aliases > 1 ? 'es' : '').": ".join(', ',@aliases).")}";
			}
			$out .= wrap(
				$summary, terminal_width, $label, $cmd_width+3+$scope_width, $cont_prefix
			)."\n";
		}
	}

	$out .= "\n$ver$hr\n";
	info({raw => 1}, $out);
	exit $rc;
} # }}}

sub command_usage { # {{{
	my ($rc, $msg) = @_;
	my $called = $CALLED;
	my $command = $GENESIS_COMMANDS{$called};

	my $hr = "#${\($rc ? 'K' : 'K')}\{" . ("=" x terminal_width) ."}";
	my $bc = $Genesis::BUILD =~ /\+\)/ ? 'R' : 'G';
	my $ver = "#gi{genesis v$Genesis::VERSION}#${bc}i{$Genesis::BUILD}\n";

	# TODO: use named colors that are dark/light aware.
	my $usage="";
	my @usage_lines = $PROPS{$command}{usage} ? split("\n",$PROPS{$command}{usage}, -1) : ($called);
	for (@usage_lines) {
		s/^$command($| )/#G{$CALLED}$1/;
		s/^<env> $command($| )/#M{<env>} #G{$CALLED}$1/;
		$usage .= "#g{${\(humanize_bin)}} ".$_."\n";
	}
	chomp $usage;

	info "\n$hr";
	my $out = "";
	$out .= wrap($PROPS{$command}{summary} || '', terminal_width, "#G{$CALLED} - ")."\n\n"
		if $PROPS{$command}{summary};

	$out .= wrap($usage,terminal_width,"#Wku{Usage:} ", 7)."\n";
	$out .= "\n".wrap(
		"#Gi{$called}#i{ is an alias to the }#Gi{$command}#i{ command}",
		terminal_width," #i{Note:} ", 7
	)."\n" unless $command eq $called;

	# TODO: List all the aliases (or other aliases if alias was used)

	if ($rc && !under_test) {
		$out .= wrap(
			"\nTo see full description with arguments and option, run ".
			"#g{${\(humanize_bin)}} #G{$called} #y{-h}",
			terminal_width
		);
		info $out;
		$msg ||= "#g{${\(humanize_bin)}} #G{$CALLED} was called incorrectly: $ENV{GENESIS_FULL_CALL}";
		fatal {show_stack => 'default'}, "\n#r{$msg}\n";
		info "$ver$hr\n";
		exit $rc;
	}

	$out .= wrap("\n$PROPS{$command}{description}",terminal_width)."\n"
		if ($PROPS{$command}{description});

	my @sources = (
		[args    => $PROPS{$COMMAND}{arguments} || [], 'Argument'],
		[vars    => $PROPS{$COMMAND}{variables} || [], 'Environmental Variable'],
		[command =>$PROPS{$COMMAND}{options} || [], 'Option'],
		[legacy  => $PROPS{$COMMAND}{deprecated_options} || []],
		[global  => [(map {@$_} @global_options[0..$PROPS{$COMMAND}{option_group}])]],
	);
	my (%options_desc, %options_def, %options_order);
	my $opt_width=0;

	for my $source_details (@sources) {
		my ($source,$options,$label) = @{$source_details};
		my $type = $label || 'Option';
		my $section=0;
		while (my ($opt_def, $opt_desc) = splice(@$options,0,2)) {

			my $opt_arg;
			if (ref($opt_desc) eq "HASH") {
				$opt_arg = $opt_desc->{argument};
				$opt_desc = $opt_desc->{description};
			}
			if ($opt_def eq '-section-break-') {
				my $sec = '-'.$section++.'-';
				push @{$options_order{$source}}, $sec;
				$options_desc{$sec} = "$opt_desc";
				next;
			}
			push @{$options_order{$source}}, $opt_def;
			$options_desc{$opt_def} = $opt_desc;

			$opt_def =~ /\^?(~?[\|a-zA-Z0-9_-]*)([\?!\+=:].*)?$/;
			bug "$type definition for $COMMAND invalid: $opt_def" unless $1;
			my ($ext,@flags) = ($2 || '', split(/\|/,$1));

			my @short_flags = grep {/^.$/} @flags;
			my @long_flags = grep {$_ !~ /^~/} grep {/^../} @flags;
			my $opt_color = $source eq 'legacy' ? 'r' : 'y';

			if ($source =~ /^(args|vars)$/) {
				my $c = $source eq 'vars' ? 'c' : $long_flags[0] eq 'env' ? 'M' : 'B';
				$options_def{$opt_def} = "#${c}{$long_flags[0]}".(
					$ext eq '?' ? " #Yi{(optional)}" : ""
				);
				next;
			}

			if ($ext eq '!') {
				$options_def{$opt_def} = "    #${opt_color}{--[no-]$long_flags[0]}";
				next;
			}

			my $opt_label = scalar(@short_flags) ? "-${\(shift @short_flags)}, " : "    ";
			$opt_label .= "--${\(shift @long_flags)}" if scalar(@long_flags);
			$opt_label =~ s/, $//; # trim comma if no long option
			unless ($opt_arg) {
				if ($ext =~ /^=([si])\@?$/) {
					$opt_arg = $1 eq 's' ? " <str>" : " <N>";
				} elsif ($ext =~ /^:([si])$/) {
					$opt_arg = $1 eq 's' ? "[=<str>]" : "[=<N>]";
				} elsif ($ext eq '+') {
					$opt_arg = ""; # TODO: find out how to indicate multiple flags allowed
				} else {
					$opt_arg = "";
				}
			}
			$options_def{$opt_def} = "#${opt_color}{$opt_label}#B{$opt_arg}";
			# TODO: save extra long and short options, and print them after the given
			# description.  Right now, they're just undocumented
		}
	}
	my $def_width = (sort {$b <=> $a} map {csize($_)} values(%options_def))[0] + 4;

	for my $source_details (@sources) {
		my ($source,$options,$label) = @{$source_details};
		next unless (defined $options_order{$source});
		($label = ($label ? $label.'s' : $source.' Options')) =~ s/.*/\u$&/; #title case;
		$out .= "\n#Wku{$label}\n";
		for (@{$options_order{$source}}) {
			if ($_ =~ /^-\d+-$/) {
				if ($options_desc{$_}) {
					$out .= "\n#i{".wrap($options_desc{$_},terminal_width)."}\n";
				} else {
					$out .= "\n";
				}
				next;
			}
			$out .= "\n".wrap($options_desc{$_}, terminal_width, "  ".$options_def{$_}, $def_width)."\n";
		}
	}

	# TODO: Integrate extended usage better than just dumping it at the end
	if (ref($PROPS{$command}{extended_usage}) eq "CODE") {
		my $extended_usage = $PROPS{$command}{extended_usage}->();
		if ($extended_usage) {
			$extended_usage =~ s/\s*$//s;
			$out .= "\n#Wku{Extended Usage Information}\n";
			$out .= "\n$extended_usage\n";
		}
	}

	info {raw => 1}, $out."\n$ver$hr\n";
	exit ($rc || 0);
} # }}}

sub set_top_path { # {{{
	# Set up current repo and env file if specified
	if (!$COMMAND_OPTIONS->{cwd} && scalar(@COMMAND_ARGS)) {
		if (has_scope('env') &&  (-f $COMMAND_ARGS[0] || -f $COMMAND_ARGS[0].'.yml')) {
			$COMMAND_OPTIONS->{cwd} = shift(@COMMAND_ARGS);
		} elsif (equivalent_commands($COMMAND, 'create') && $COMMAND_ARGS[0] =~ /(.*)\/[^\/]+?(.yml)?$/ && -d $1) {
			$COMMAND_OPTIONS->{cwd} = shift(@COMMAND_ARGS);
		}
	}
	if ($COMMAND_OPTIONS->{cwd}) {
		my $requested_cwd = delete($COMMAND_OPTIONS->{cwd});
		my $cwd = abs_path($requested_cwd);
		bail(
			"Path '%s' specified in -C option does not exist",
			$requested_cwd
		) unless $cwd;

		if ( -f $cwd || -f "${cwd}.yml" ) {
			bail(
				"#B{%s %s} cannot be called specifying a file as an argument",
				__FILE__, $COMMAND
			) unless has_scope('env');
			unshift(@COMMAND_ARGS, basename($cwd));
			$cwd = dirname($cwd);
		} elsif ($COMMAND eq 'create' && ! -d $cwd) {
			unshift(@COMMAND_ARGS, basename($cwd));
			$cwd = dirname($cwd);
		}

		chdir_or_fail($cwd);
		return 1;
	}
	return;
} # }}}

sub set_logging_state { # {{{

	# Logging
	my $log_level = delete($COMMAND_OPTIONS->{log});
	my $debug = delete($COMMAND_OPTIONS->{debug}) || 0;
	my $trace = delete($COMMAND_OPTIONS->{trace}) || 0;

	# TODO: make this obsolete in 3.0.0
	if ($log_level) {
		warning "Option --log|-l takes precedence over -D and -T options"
			if ($debug || $trace);
		$log_level = Genesis::Log::find_log_level($log_level)
	} else {
		$log_level = 'DEBUG' if ($debug);
		$log_level = 'TRACE' if ($trace);
	}
	$log_level ||= 'INFO';

	$ENV{GENESIS_DEBUG}  = 'y' if Genesis::Log::meets_level($log_level, 'DEBUG');
	$ENV{GENESIS_TRACE}  = 'y' if Genesis::Log::meets_level($log_level, 'TRACE');

	my $stack_trace = delete($COMMAND_OPTIONS->{'show-stack'});
	$ENV{GENESIS_STACK_TRACE} = "y" if delete($COMMAND_OPTIONS->{'show-stack'});

	$Logger->configure_log(
		level => $log_level,
		style => $ENV{GENESIS_LOG_STYLE} // $Genesis::RC->get('output_style','plain'),
		show_stack => ($stack_trace ? ($stack_trace == 1 ? 'fatal' : $stack_trace == 2 ? 'current' : 'full' ) : undef),
	);
} # }}}

sub build_command_environment  { # {{{

	# spruce debugging
	my $spruce_log = delete($COMMAND_OPTIONS->{'spruce-log'});
	if ($spruce_log) {
		my @spruce_log_levels = grep {$_ =~ qr/^$spruce_log.*/i} (qw[debug trace]);
		bail "--spruce-log is expected to be one of TRACE or DEBUG"
			if (scalar(@spruce_log_levels) != 0);

		$spruce_log = $spruce_log_levels[0];
		$ENV{DEBUG} = 'y' if $spruce_log ;
		$ENV{TRACE} = 'y' if $spruce_log eq 'trace';
	}

	$ENV{GENESIS_EXECUTABLE_ENVS} = $Genesis::RC->get('executable_envs', 0);
	$ENV{GENESIS_BOSH_ENVIRONMENT} = delete($COMMAND_OPTIONS->{'bosh-env'}) if $COMMAND_OPTIONS->{'bosh-env'};
	$ENV{GENESIS_BOSH_ENVIRONMENT} ||= '';

	# Set BOSH CPI for debugging/testing purposes - name is due to legacy usage by testkit Golang library
	$ENV{GENESIS_TESTING_BOSH_CPI} = delete($COMMAND_OPTIONS->{'cpi'}) if $COMMAND_OPTIONS->{'cpi'};

	if ($COMMAND_OPTIONS->{config} && ref($COMMAND_OPTIONS->{config}) eq 'ARRAY') {
		my %configs;
		for (@{$COMMAND_OPTIONS->{config}}) {
			my ($type,$name,$path) = $_ =~ m/^(?:(cc|rc|[a-z0-9_-]*?)(?:@([^=]*))?=)?(.*)$/;
			$type = 'cloud' if !defined($type) || $type eq 'cc';
			$type = 'runtime'  if $type eq 'rc';
			$type =~ s/-config$//;
			$path = Cwd::abs_path($path)
				or bail "$path: no such file or directory";
			my $var = uc("GENESIS_${type}_CONFIG") . ($name ? "_$name" : '');
			$ENV{$var} = $path;
			$configs{$type."@".($name||'default')} = $path;
		}
		delete($COMMAND_OPTIONS->{config});
		$COMMAND_OPTIONS->{config} = {%configs} if %configs;
	}
} # }}}

sub has_scope { # {{{
# has_scope returns true if any of the specified scopes are true for the
# current command with its specified options.
#
# The scope is determined by checking the commands scope specification against
# the options of the given call.
#
# In the simplest situation, if the command scope specification is a string,
# that is compared to the queried scopes and returns true if it matcheds any of
# them.
#
# If however, the command scope is an array, then each element is checked in
# order.  Each array element is a scope fragment, consisting of an option
# compariton (or an arrao of option comparisons), and a list of scopes.  The
# option comparisons each can be one of the following expression types*:
#   opt_name - matches boolean true
#  !opt_name - matches boolean false
#   opt_name=value - true if option 'opt_name' is set to the given value 'value'
#  !opt_name=value - true if option 'opt_name' is any other value than 'value'
#
# For the scopes to be considered applicable, all option comparisons must be true.
# The final element can be a single string, indicating a default scope, with no
# option comparisons to be applied.  The first match (or default) will be
# considered the only valid scopes for the current options of the current call.
#
# * if needed, support for regex or value comparisons can be easily added in the
# future
#
# TODO:  Support complex requests such as:
#   has_scope(['all' => [<list of scopes>]]) : all scopes specified must be applicable
#     - work-around: has_scope('scope1') && has_scope('scope2') && ...
#   has_scope(['any' => [<list of scopes>]]) : any scopes specified must be applicable
#     - default if arrays is specified
#   has_scope(['none' => [<list of scopes>]]) : no scope specified must be applicable
#     - work around: (!any)
#   has_scope(['not' => [<list of scopes>]]) : all of these scopes specified must not be applicable
#     - work around: (!all)
#   has_scope(['any_other' => [<list of scopes>]]) : at least one scope OTHER than those specified must be applicable
#     - no work around at this time
#   has_scope(['any_but' => [<list of scopes>]]) : at least one scope excluding any specified must be applicable
#     - other & !any
#
	my @allowed_scopes = @_;
	my $command_scopes = $PROPS{$COMMAND}{scope} or return 0; # no scope required
	$command_scopes = [$command_scopes] unless ref($command_scopes) eq 'ARRAY';

	my %requested_scopes;
	$requested_scopes{$_}=1 for (@allowed_scopes);

	for my $scope_fragment (@$command_scopes) {
		if (ref($scope_fragment) eq 'ARRAY') {
			bug('Incorrectly defined scope for command $COMMAND') unless scalar(@$scope_fragment) == 2;
			my ($opt_names, $opt_scopes) = @$scope_fragment;
			$opt_names = [$opt_names] unless ref($opt_names) eq 'ARRAY';
			$opt_scopes = [$opt_scopes] unless ref($opt_scopes) eq 'ARRAY';
			my $match = 1;
			for my $opt_name (@$opt_names) {
				(my $negate,$opt_name,my $value) = $opt_name =~ m/^(!)?([^=]*)(?:=(.*))?$/;
				my $check = defined($value)
					? defined($COMMAND_OPTIONS->{$opt_name}) && $COMMAND_OPTIONS->{$opt_name} eq $value
					: $COMMAND_OPTIONS->{$opt_name};
				$match = $match && ($check xor $negate);
			}
			return 1 if $match && scalar(grep {$requested_scopes{$_}} @$opt_scopes);
		} else {
			return 1 if $requested_scopes{$scope_fragment};
		}
	}

	return;
} # }}}

sub check_embedded_genesis { # {{{

	return if envset("GENESIS_IS_HELPING_YOU");
	return if $Genesis::RC->get('embedded_genesis','ignore') eq 'ignore';
	return unless has_scope qw(repo env);

	require Genesis::Top;
	my $top = Genesis::Top->new('.', no_vault => 1);
	my $embedded_genesis = $top->path('.genesis/bin/genesis');
	return unless -f $embedded_genesis;
	return if envset("GENESIS_USING_EMBEDDED");
	return if $ENV{GENESIS_CALLBACK_BIN} eq $embedded_genesis;

	# Get embedded contents
	open my $fh,  '<',  $embedded_genesis;
	while(<$fh>) {last if /^__(END|DATA)__$/};
	my $sha = <$fh>;
	my $contents = do { local $/; <$fh> };
	close $fh;

	# Check if embedded genesis is present, compressed, and valid
	unless (require MIME::Base64) {
		debug "Can't import MIME::Base64 - can't check embedded genesis";
		return;
	}
	MIME::Base64->import(qw(decode_base64));
	unless (require IO::Uncompress::Gunzip) {
		debug "Can't import IO::Uncompress::Gunzip - can't check embedded genesis";
		return;
	}
	IO::Uncompress::Gunzip->import(qw(gunzip $GunzipError));

	my $bincontents = decode_base64($contents);
	my $z = IO::Uncompress::Gunzip->new( \$bincontents );
	my $tar = do { local $/; <$z>};
	close $z;

	(grep {/^\$Genesis::VERSION = \"(.*)\"/} split("\n",$tar))[0] =~ /^\$Genesis::VERSION = \"(.*)\"/;
	my $embedded_version = $1;
	return if ($embedded_version eq $Genesis::VERSION);
	if ($Genesis::RC->get('embedded_genesis','ignore') ne "use" || command_properties->{no_use_embedded_genesis}) {
		warning(
			"Embedded genesis is $embedded_version, current version is $Genesis::VERSION"
		);
		return;
	}

	info "#Y{Running embedded Genesis ($embedded_version)...}\n";
	my $embedded_root = workdir();
	open my $bin, "|-", "tar -xzf - -C $embedded_root"
		or bail("Could not use extract embedded Genesis");
	print $bin $bincontents;
	close $bin;

	# run it!
	$ENV{GENESIS_CALLBACK_BIN}   = "$embedded_root/genesis";
	$ENV{GENESIS_LIB}            = "$embedded_root/lib";
	$ENV{GENESIS_USING_EMBEDDED} = 1;
	chmod 0755, "$embedded_root/genesis";
	exit(system "$embedded_root/genesis", @ARGV);
} # }}}

sub check_version { # {{{
	my ($name, $min, $cmd, @remainder) = @_;
	my ($version, $regex, $url, $path);
	if ($cmd) {
		($regex, $url, my $path_src) = @remainder;
		($version) = run({ stderr => undef }, $cmd);
		$path_src = (grep {$_ !~ /=/} split(" ", $cmd))[0] unless $path_src;
		($path) = run({stderr => undef}, 'type -p $1', $path_src);
	} else {
		($version, $path, $url) = @remainder;
	}

	$url ||= "your platform package manager";

	return "#R{Missing `$name`} -- install from #B{$url}"
		if !$version || $version =~ /not found/;

	if (envset('GENESIS_DEV_MODE') && $version =~ /development/) {
		debug("#Y{Version $version} of #C{$name} (development) being used - minimum of #W{$min} needed.");
		return;
	}

	my $v = $version;
	if ($regex) {
		$version =~ $regex; $v = $1;
		return "Could not determine version of $name from `#M{$cmd}`: Got '#C{$version}'"
			unless $v && semver($v);
	}

	$path = humanize_path($path);
	return "$name v${v} is installed at $path, but Genesis requires #R{at least $min} -- please upgrade via #B{$url}"
		unless new_enough($v, $min);

	debug("#G{Version $v} of #C{$name} ($path) meets or exceeds minimum of #w{$min}");
	return; # no error
} # }}}

sub check_prereqs { # {{{
	CORE::state $prereqs_checked = 0; # static variables
	return 1 if envset("GENESIS_IS_HELPING_YOU") || $prereqs_checked;
	bug "check_prereqs called before command selected" unless current_command;

	my $bosh_min_version = "6.4.4";
	my $perl_version = join('.',map {$_+0}  ($] =~ m/(\d*)\.(\d{3})(\d{3})/));
	my $reqs = [
		# Name,     Version, Command,                                 Pattern                   Source
		["perl",   "5.20.0", "", $perl_version, $^X],
		["curl",   "7.30.0", "curl --version 2>/dev/null | head -n1",                  qr(^curl\s+(\S+))],
		["git",     "1.8.0", "git --version  2>/dev/null",                             qr(.*version\s+(\S+).*)],
		["jq",        "1.6", "jq --version   2>/dev/null",                             qr(^jq-([\.0-9]+)),       "https://stedolan.github.io/jq/download/"],
		["spruce", "1.28.0", "spruce -v      2>/dev/null",                             qr(.*version\s+(\S+).*)i, "https://github.com/geofffranks/spruce/releases"],
		["safe",    "1.6.1", "safe -v        2>&1 >/dev/null",                         qr(safe v(\S+)),          "https://github.com/starkandwayne/safe/releases"],
		["vault",   "0.9.0", "vault -v       2>/dev/null",                             qr(.*vault v(\S+).*)i,    "https://www.vaultproject.io/downloads.html"],
		["credhub", "2.7.0", "CREDHUB_SERVER='' credhub --version 2>/dev/null",        qr(CLI Version: (\S+)),   "https://github.com/cloudfoundry-incubator/credhub-cli/releases"],
	];

	my @errors = grep {$_} map {
		my $err = check_version(@$_);
		debug_error $err if $err;
		$err
	} @$reqs;

	# check that we has a bosh (v2)
	require Service::BOSH;
	eval {$ENV{GENESIS_BOSH_COMMAND} = Service::BOSH->command($bosh_min_version)};
	if ($@) {
		push @errors, $@ =~ s/^\s*.*\[[^ ]*\][^ ]* //mr;
	}

	# Check Scope requirements
	if (has_scope(['repo','env'])) {
		push @errors, csprintf(
			"The '#B{%s %s}' command needs to be run from a Genesis deployment\n    ".
			"repo, or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			unless in_repo_dir;
	} elsif (has_scope(['kit'])) {
		push @errors, csprintf(
			"The '#B{%s %s}' command needs to be run from a Genesis kit repo,\n    ".
			"or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			unless in_kit_dir;
	} elsif (has_scope(['kit_or_dev'])) {
		push @errors, csprintf(
			"The '#B{%s %s}' command needs to be run from a Genesis kit repo or a\n    ".
			"deployment repo with a dev kit, or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			unless in_kit_dir || (in_repo_dir && -d 'dev');
	} elsif (has_scope('empty')) {
		push @errors, csprintf(
			"The '#B{%s %s}' command cannot be run from a Genesis deployment\n    ".
			"or kit repo, or specify one using -C <dir> option",humanize_bin(), $COMMAND )
			if in_repo_dir || in_kit_dir;
	}
	# TODO: Validate pipeline scope (must at least be in a repo?)

	debug "Terminal encoding: '%s'", $ENV{LANG} || '<undefined>';

	bail(
		"#R{GENESIS PRE-REQUISITES CHECKS FAILED!!}\n".
		"\n".
		"Encountered the following errors:\n".
		join("", map {"[[  - >>$_\n"} @errors)
	) if (@errors);
	$prereqs_checked=1;
} # }}}

sub at_exit { # {{{
	my ($fn) = @_;
	push @$END_HOOKS, $fn;
}

END {
	$_->($?) for @$END_HOOKS;
} # }}}

1;

# vim: fdm=marker:foldlevel=0:noet
