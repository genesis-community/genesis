package Genesis::Commands::Utility;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::UI;

# genesis prompt support routines: *_prompt_handlers {{{

sub validate_prompt_opts {
	my ($type,$opts,@valid_opts) = @_;
	my @invalid_opts;
	for my $opt (keys %$opts) {
		push @invalid_opts, $opt unless grep {$_ eq $opt} @valid_opts;
	}
	if (@invalid_opts) {
		error("#R{ERROR:} %s prompt does not support option(s) '%s'", $type, join("', '", @invalid_opts));
		error("Contact your kit author for a fix.");
		exit 2;
	}
}

sub line_prompt_handler {
	my ($prompt, %opts) = @_;
	validate_prompt_opts("line", \%opts, qw(label default validation msg inline));
	if ($opts{inline}) {
		die "Cannot request both label and inline options to prompt_for line\n"
			if defined($opts{label});
		$opts{label} = $prompt;
		$prompt=undef;
	}
	if (defined($opts{validation}) && !ref($opts{validation}) && $opts{validation} =~ /^vault_path/) {
		require Genesis::Vault;
		my $vault = Genesis::Vault->current || Genesis::Vault->rebind();
		bail("No vault selected!") unless $vault;
	}
	return prompt_for_line($prompt, $opts{label},$opts{default},$opts{validation},$opts{msg})
}

sub boolean_prompt_handler {
	my ($prompt, %opts) = @_;
	validate_prompt_opts("boolean", \%opts, qw(default invert inline));
	$prompt .= ' [y|n]' if $opts{inline};
	return prompt_for_boolean($prompt, $opts{default}, $opts{invert}) ? "true" : "false";
}
sub block_prompt_handler {
	my ($prompt, %opts) = @_;
	validate_prompt_opts("block", \%opts, qw());
	return prompt_for_block($prompt);
}
sub select_prompt_handler {
	my ($prompt, %opts) = @_;
	validate_prompt_opts("select", \%opts, qw(label default option));
	my (@choices,@labels);
	die "No options provided to prompt for select\n" unless $opts{option} && @{$opts{option}};
	for (@{$opts{option}}) {
		$_ =~ m/^(\[(.*?)\]\s*)?(\S.*)$/;
		push @labels, $3;
		push @choices, $1 ? $2 : $3;
	}
	return prompt_for_choice($prompt,\@choices, $opts{default}, \@labels, $opts{msg});
}
sub multi_line_prompt_handler {
	my ($prompt, %opts) = @_;
	validate_prompt_opts("multi-line", \%opts, qw(label min max validation msg));
	if (defined($opts{validation}) && !ref($opts{validation}) && $opts{validation} =~ /^vault_path/) {
		require Genesis::Vault;
		my $vault = Genesis::Vault->current || Genesis::Vault->rebind();
		bail("No vault selected!") unless $vault;
	}
	my $results = prompt_for_list('line',$prompt,$opts{label},$opts{min},$opts{max},$opts{validation},$opts{msg});
	return join("\0", @$results, '');
}
sub multi_block_prompt_handler {
	my ($prompt, %opts) = @_;
	validate_prompt_opts("multi-block", \%opts, qw(label min max msg));
	my $results = prompt_for_list('block',$prompt,$opts{label},$opts{min},$opts{max},undef,$opts{msg});
	return join("\0", @$results, '');
}
sub multi_select_prompt_handler {
	my ($prompt, %opts) = @_;
	validate_prompt_opts("multi-select", \%opts, qw(label min max option));
	my (@choices,@labels);
	die "No options provided to prompt for select\n" unless $opts{option} && @{$opts{option}};
	for (@{$opts{option}}) {
		$_ =~ m/^(\[(.*?)\]\s*)?(\S.*)$/;
		push @labels, $3;
		push @choices, $1 ? $2 : $3;
	}
	my $results = prompt_for_choices($prompt,\@choices, $opts{min}, $opts{max}, \@labels, $opts{msg});
	return "" unless scalar @$results;
	return join("\0", @$results, '');
}
sub secret_line_prompt_handler {
	my ($prompt,%opts) = @_;
	my $secret = delete $opts{secret};
	my $env = delete $opts{env};
	validate_prompt_opts("secret-line", \%opts, qw(echo));

	my $vault;
	if ($env && $env->kit->feature_compatibility('2.7.0-rc4')) {
		$secret = $env->secrets_base.$secret unless $secret =~ /^\//;
		$vault = $env->vault;
	} else {
		$secret = "secret/$secret";
		require Genesis::Vault;
		$vault = Genesis::Vault->current || Genesis::Vault->rebind();
	}
	my ($path, $key) = split /:/, $secret;
	bail("No vault selected!") unless $vault;
	print "\n";
	$vault->query(
		{ interactive => 1, onfailure => "Failed to save data to #C{$secret} in vault" },
		'prompt', $prompt, '--', ($opts{echo} ? "ask" : "set"), $path, $key);
}
sub secret_block_prompt_handler {
	my ($prompt,%opts) = @_;
	my $secret = delete $opts{secret};
	my $env = delete $opts{env};
	validate_prompt_opts("secret-block", \%opts, ());
	my $file = mkfile_or_fail(workdir()."/param", prompt_for_block($prompt));

	my $vault;
	if ($env && $env->kit->feature_compatibility('2.7.0-rc4')) {
		$secret = $env->secrets_base.$secret unless $secret =~ /^\//;
		$vault = $env->vault;
	} else {
		$secret = "secret/$secret";
		require Genesis::Vault;
		$vault = Genesis::Vault->current || Genesis::Vault->rebind();
	}
	my ($path, $key) = split /:/, $secret;
	bail("No vault selected!") unless $vault;
	print "\n";
	$vault->query(
		{ onfailure => "Failed to save data to #C{$secret} in vault" },
		'set', $path, sprintf('%s@%s', $key, $file)
	);
}

our $prompt_handlers = {
	line =>           \&line_prompt_handler,
	boolean =>        \&boolean_prompt_handler,
	block =>          \&block_prompt_handler,
	select =>         \&select_prompt_handler,

	list         =>   \&multi_line_prompt_handler,
	lines        =>   \&multi_line_prompt_handler,
	"multi-line" =>   \&multi_line_prompt_handler,

	blocks        =>  \&multi_block_prompt_handler,
	"multi-block" =>  \&multi_block_prompt_handler,

	"multi-select" => \&multi_select_prompt_handler,
	"secret-line" =>  \&secret_line_prompt_handler,
	"secret-block" => \&secret_block_prompt_handler,
};

# }}}

sub ui_prompt_for {

	command_usage(1) if @_ < 2; # prompt is optional, type and path are not
	my ($type,$path,@prompt_lines) = @_;
	my $prompt = join("\n",@prompt_lines);
	my $use_vault = ($type =~ /^secret-*/);
	if ($use_vault) {
		get_options->{secret} = $path;
		eval {
			require Genesis::Top;
			get_options->{env} = Genesis::Top->new($ENV{GENESIS_ROOT})->load_env($ENV{GENESIS_ENVIRONMENT});
		};
		if ($@) {
			debug "Failed in ui-prompt-for attempting to load environment:\n$@";
			bail "#R{[ERROR]} Cannot prompt for secrets outside a kit hook";
		}
	}

	bail(
		"#R{ERROR:} cannot prompt for %s: unknown type, expecting one of: %s\n",
		$type,
		join(", ", (sort keys %$prompt_handlers))
	) unless exists($prompt_handlers->{$type});

	my $result = $prompt_handlers->{$type}->($prompt,%{get_options()});
	mkfile_or_fail($path, $result) unless $use_vault;
	exit 0
}
# }}}



1;
