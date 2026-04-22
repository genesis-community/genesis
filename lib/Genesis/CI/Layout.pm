package Genesis::CI::Layout;
use strict;
use warnings;

### Public Methods {{{

# parse - parse a layout DSL string into a structured layout hashref {{{
#
# DSL syntax:
#   auto pattern*             - one or more glob patterns; matched envs are auto-triggered
#   env1 -> env2 -> env3      - progression chain (env1 triggers env2 triggers env3)
#   Rules are separated by semicolons or newlines.
#
# Options:
#   known_envs => [...]       - list of valid env names for validation and auto-pattern
#                               expansion; if omitted, any identifier is accepted as an
#                               env name and auto patterns expand against seen envs
#
# Returns a hashref with:
#   auto         => [...]              - env names that should be auto-triggered
#   envs         => [...]              - all env names seen in the DSL
#   will_trigger => { A => [B, C] }   - A triggers B, C on successful deploy
#   triggers     => { B => A }        - inverse: B is triggered by A
#
# Dies with a descriptive message on syntax or semantic errors.
sub parse {
	my ($class, $src, %opts) = @_;

	my $known = $opts{known_envs};     # optional arrayref
	my %known_set = map { $_ => 1 } @{$known || []};

	# ----------------------------------------------------------------
	# Tokenize
	# ----------------------------------------------------------------
	# Strip comments, collapse newlines to ';' terminators
	$src =~ s/\s*#.*$//gm;
	$src =~ s/[\r\n]+/ ; /g;
	$src =~ s/(^\s+|\s+$)//;

	# Split into rules (each rule is an arrayref of tokens)
	my @rules;
	my $rule = [];
	for my $tok (split /\s+/, "$src ;") {
		next unless length($tok);
		if ($tok eq ';') {
			push @rules, $rule if @$rule;
			$rule = [];
			next;
		}
		push @$rule, $tok;
	}

	# ----------------------------------------------------------------
	# Interpret rules
	# ----------------------------------------------------------------
	my @auto_patterns;    # raw glob patterns from 'auto' directives
	my %envs;             # de-duplicating set of all seen env names
	my %will_trigger;     # A => [B, C, ...] trigger graph

	for my $r (@rules) {
		my ($cmd, @args) = @$r;

		# --- auto directive ---
		if ($cmd eq 'auto') {
			die "The 'auto' directive requires at least one argument.\n"
				unless @args;
			push @auto_patterns, @args;
			next;
		}

		# --- bare '->' at start of rule is always invalid ---
		if ($cmd eq '->') {
			die "Unexpected '->' at start of rule.\n";
		}

		# --- env chain: env [ -> env ]* ---
		# Validate first token against known_envs if provided
		if ($known && !$known_set{$cmd}) {
			die "Unrecognized environment '$cmd': not in known_envs list.\n";
		}

		my $orig = join ' ', @$r;
		my @tokens = @$r;
		while (@tokens) {
			my $env = shift @tokens;
			$envs{$env} = 1;

			my $sep = shift @tokens;   # '->' or undef
			last unless defined $sep;

			die "Invalid pipeline definition '$orig': expecting '<env> [-> <env>]...'.\n"
				unless $sep eq '->';

			my $target = $tokens[0];
			die "Missing target after -> in pipeline definition '$orig'.\n"
				unless defined $target && length $target;

			# Validate target against known_envs if provided
			if ($known && !$known_set{$target}) {
				die "Unrecognized environment '$target': not in known_envs list.\n";
			}

			push @{$will_trigger{$env}}, $target;
		}
	}

	my @envs = keys %envs;

	# ----------------------------------------------------------------
	# Expand auto patterns
	# ----------------------------------------------------------------
	# Expand against known_envs (if provided) or envs seen in the DSL
	my @expansion_pool = $known ? @$known : @envs;
	my %auto_envs;
	for my $pattern (@auto_patterns) {
		# Build a safe regex: escape metacharacters in literal segments,
		# then replace \* (escaped asterisk) with .* for glob semantics.
		my $regex = join('.*', map { quotemeta($_) } split(/\*/, $pattern, -1));
		$regex = qr/^$regex$/;

		my $matched = 0;
		for my $env (@expansion_pool) {
			if ($env =~ $regex) {
				$auto_envs{$env} = 1;
				$matched++;
			}
		}
		warn "warning: rule 'auto $pattern' did not match any environments.\n"
			unless $matched;
	}

	# ----------------------------------------------------------------
	# Build trigger inverse map
	# ----------------------------------------------------------------
	# Also validates that no env is triggered by more than one other env.
	my %triggers;
	for my $a (keys %will_trigger) {
		for my $b (@{$will_trigger{$a}}) {
			if ($triggers{$b} && $triggers{$b} ne $a) {
				die "Environment '$b' is already triggered by '$triggers{$b}'."
					. " An environment may not be triggered more than once.\n";
			}
			$triggers{$b} = $a;
		}
	}

	return {
		auto         => [keys %auto_envs],
		envs         => \@envs,
		will_trigger => \%will_trigger,
		triggers     => \%triggers,
	};
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Layout - Standalone parser for the Genesis pipeline layout DSL

=head1 DESCRIPTION

Parses the Genesis CI pipeline layout DSL (as found in C<pipeline.layout> /
C<pipeline.layouts> in legacy C<ci.yml>) into a structured hashref that can
be consumed by any CI provider or workflow builder.

The DSL has two rule types, separated by semicolons or newlines:

  auto pattern*          - one or more glob patterns; matching envs are auto-triggered
  env1 -> env2 -> env3   - progression chain; each env triggers the next on success

=head1 SYNOPSIS

  use Genesis::CI::Layout;

  my $layout = Genesis::CI::Layout->parse($dsl_string);
  # or with env-name validation:
  my $layout = Genesis::CI::Layout->parse($dsl_string, known_envs => \@env_names);

  # Returned structure:
  #   $layout->{auto}         - arrayref of env names that are auto-triggered
  #   $layout->{envs}         - arrayref of all env names seen
  #   $layout->{will_trigger} - hashref: A => [B, C] (A triggers B and C)
  #   $layout->{triggers}     - hashref: B => A      (B is triggered by A)

=head1 OPTIONS

=over 4

=item B<known_envs>

An optional arrayref of valid environment names.  When provided:

=over 4

=item * Any env name in the DSL that is not in C<known_envs> causes an error.

=item * Auto patterns are expanded against C<known_envs> rather than only
the envs seen in the DSL.

=back

=back

=head1 ERRORS

C<parse> dies with a descriptive message for:

=over 4

=item * C<auto> directive with no arguments

=item * C<-> used without a valid left-hand env (bare C<< -> >> at start)

=item * Invalid separator in an env chain (expected C<< -> >>)

=item * Missing target after C<< -> >>

=item * Unknown env name when C<known_envs> is provided

=item * An environment triggered by more than one other environment

=back

=head1 SEE ALSO

Genesis::CI::Compiler::Parser, Genesis::CI::Compiler::ASTBuilder

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
