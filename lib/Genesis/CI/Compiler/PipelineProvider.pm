package Genesis::CI::Compiler::PipelineProvider;
use strict;
use warnings;

use Genesis;
use JSON::PP;

### Constructor {{{

# new - create a new provider instance {{{
sub new {
	my ($class, %opts) = @_;

	bug("Cannot instantiate Genesis::CI::Compiler::PipelineProvider directly; ".
		"use a subclass instead")
		if $class eq __PACKAGE__;

	return bless({
		ast => $opts{ast},
		top => $opts{top},
	}, $class);
}

# }}}
# }}}
### Abstract Methods {{{
#
# Subclasses MUST override these methods.

# platform_name - return human-readable platform name {{{
sub platform_name {
	my ($self) = @_;
	bug("Subclass '%s' must implement platform_name()", ref($self));
}

# }}}
# generate_from_ast - generate platform-specific output from AST {{{
sub generate_from_ast {
	my ($self, $ast) = @_;
	bug("Subclass '%s' must implement generate_from_ast()", ref($self));
}

# }}}
# output_files - describe what files this provider generates {{{
sub output_files {
	my ($self) = @_;
	bug("Subclass '%s' must implement output_files()", ref($self));
}

# }}}
# }}}
### Shared Helper Methods {{{

# ast - get stored AST {{{
sub ast {
	return $_[0]->{ast};
}

# }}}
# top - get stored Genesis::Top object {{{
sub top {
	return $_[0]->{top};
}

# }}}
# dump_yaml - serialize data structure to YAML string {{{
sub dump_yaml {
	my ($self, $data) = @_;

	# Use JSON::PP for a reliable serialization, then convert to YAML-like format
	# This avoids depending on YAML::PP which may not be available
	return _to_yaml($data, 0);
}

# }}}
# git_uri - build git URI from source_control config {{{
sub git_uri {
	my ($self, $source_control) = @_;
	$source_control ||= ($self->{ast} ? $self->{ast}->integrations->{source_control} : {});

	my $provider = $source_control->{provider} || '';
	my $repo     = $source_control->{repository} || '';

	if ($provider eq 'github') {
		return sprintf("git\@github.com:%s.git", $repo);
	} elsif ($provider eq 'gitlab') {
		return sprintf("git\@gitlab.com:%s.git", $repo);
	} elsif ($source_control->{uri}) {
		return $source_control->{uri};
	} else {
		return $repo;
	}
}

# }}}
# secret_ref - format a secret reference for this platform {{{
sub secret_ref {
	my ($self, $ref) = @_;
	return undef unless defined $ref;

	# Unwrap secret_ref hash
	if (ref($ref) eq 'HASH' && exists $ref->{secret_ref}) {
		$ref = $ref->{secret_ref};
	}

	# Default Concourse format; override in subclass for other platforms
	return "(($ref))";
}

# }}}
# topological_sort - standard topological sort on workflow graph {{{
sub topological_sort {
	my ($self, $graph) = @_;

	my @sorted;
	my %visited;
	my %temp_mark;

	my $visit;
	$visit = sub {
		my ($node) = @_;
		return if $visited{$node};
		bail("Cycle detected in workflow graph at node '%s'", $node)
			if $temp_mark{$node};

		$temp_mark{$node} = 1;

		for my $edge (@{$graph->{edges} || []}) {
			if ($edge->{from} eq $node) {
				$visit->($edge->{to});
			}
		}

		delete $temp_mark{$node};
		$visited{$node} = 1;
		unshift @sorted, $node;
	};

	for my $node (sort keys %{$graph->{nodes} || {}}) {
		$visit->($node) unless $visited{$node};
	}

	return @sorted;
}

# }}}
# matches_pattern - check if a target name matches a glob pattern {{{
sub matches_pattern {
	my ($self, $name, $pattern) = @_;

	my $regex = $pattern;
	$regex =~ s/\*/.*/g;
	$regex =~ s/\?/./g;

	return $name =~ /^$regex$/;
}

# }}}
# }}}
### Internal Helpers {{{

# _to_yaml - simple YAML serializer (no external dependency) {{{
sub _to_yaml {
	my ($data, $indent) = @_;
	$indent //= 0;
	my $prefix = '  ' x $indent;

	if (!defined $data) {
		return "~";
	} elsif (ref($data) eq 'HASH') {
		my @lines;
		for my $key (sort keys %$data) {
			my $val = $data->{$key};
			if (!defined $val) {
				push @lines, "${prefix}${key}: ~";
			} elsif (!ref($val)) {
				push @lines, "${prefix}${key}: " . _yaml_scalar($val);
			} elsif (ref($val) eq 'ARRAY' && !@$val) {
				push @lines, "${prefix}${key}: []";
			} elsif (ref($val) eq 'HASH' && !%$val) {
				push @lines, "${prefix}${key}: {}";
			} elsif (ref($val) eq 'ARRAY') {
				push @lines, "${prefix}${key}:";
				push @lines, _to_yaml_array($val, $indent + 1);
			} elsif (ref($val) eq 'HASH') {
				push @lines, "${prefix}${key}:";
				push @lines, _to_yaml($val, $indent + 1);
			} else {
				push @lines, "${prefix}${key}: " . _yaml_scalar("$val");
			}
		}
		return join("\n", @lines);
	} elsif (ref($data) eq 'ARRAY') {
		return _to_yaml_array($data, $indent);
	} else {
		return "${prefix}" . _yaml_scalar($data);
	}
}

# }}}
# _to_yaml_array - serialize array to YAML {{{
sub _to_yaml_array {
	my ($data, $indent) = @_;
	my $prefix = '  ' x $indent;
	my @lines;

	for my $item (@$data) {
		if (!defined $item) {
			push @lines, "${prefix}- ~";
		} elsif (!ref($item)) {
			push @lines, "${prefix}- " . _yaml_scalar($item);
		} elsif (ref($item) eq 'HASH') {
			my @keys = sort keys %$item;
			if (@keys) {
				my $first = shift @keys;
				my $val = $item->{$first};
				if (!ref($val)) {
					push @lines, "${prefix}- ${first}: " . _yaml_scalar($val);
				} else {
					push @lines, "${prefix}- ${first}:";
					push @lines, _to_yaml($val, $indent + 2);
				}
				for my $key (@keys) {
					$val = $item->{$key};
					if (!ref($val)) {
						push @lines, "${prefix}  ${key}: " . _yaml_scalar($val);
					} else {
						push @lines, "${prefix}  ${key}:";
						push @lines, _to_yaml($val, $indent + 2);
					}
				}
			} else {
				push @lines, "${prefix}- {}";
			}
		} elsif (ref($item) eq 'ARRAY') {
			push @lines, "${prefix}-";
			push @lines, _to_yaml_array($item, $indent + 1);
		}
	}

	return join("\n", @lines);
}

# }}}
# _yaml_scalar - format a scalar value for YAML output {{{
sub _yaml_scalar {
	my ($val) = @_;

	# Booleans
	if (ref($val) eq 'JSON::PP::Boolean') {
		return $val ? 'true' : 'false';
	}

	# Numbers
	if ($val =~ /^-?\d+(\.\d+)?$/ && $val !~ /^0\d/) {
		return $val;
	}

	# Simple strings that don't need quoting
	if ($val =~ /^[a-zA-Z0-9_.\/-]+$/ && $val !~ /^(true|false|null|yes|no|on|off)$/i) {
		return $val;
	}

	# Multi-line strings
	if ($val =~ /\n/) {
		my @lines = split /\n/, $val;
		return "|\n" . join("\n", map { "  $_" } @lines);
	}

	# Strings that need quoting
	$val =~ s/\\/\\\\/g;
	$val =~ s/"/\\"/g;
	return "\"$val\"";
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler::PipelineProvider - Abstract base class for CI providers

=head1 DESCRIPTION

Genesis::CI::Compiler::PipelineProvider is the abstract base class for CI
platform providers in the compiler pipeline. Each provider takes a
Genesis::CI::Compiler::AST and generates platform-specific configuration.

=head1 SYNOPSIS

  package Genesis::CI::Compiler::Providers::MyPlatform;
  use parent 'Genesis::CI::Compiler::PipelineProvider';

  sub platform_name { "My Platform" }

  sub generate_from_ast {
    my ($self, $ast) = @_;
    # Generate platform-specific output
    return { 'pipeline.yml' => $yaml_string };
  }

  sub output_files {
    return { 'pipeline.yml' => 'Pipeline definition' };
  }

=head1 SHARED HELPERS

=head2 dump_yaml($data)

Serialize a Perl data structure to YAML string.

=head2 git_uri($source_control)

Build a git URI from source control configuration.

=head2 secret_ref($ref)

Format a secret reference for this platform. Default: C<(($ref))>.

=head2 topological_sort($graph)

Perform topological sort on a workflow graph. Bails on cycles.

=head2 matches_pattern($name, $pattern)

Check if a name matches a glob pattern (C<*> and C<?>).

=head1 SEE ALSO

Genesis::CI::Compiler::AST, Genesis::CI::Concourse, Genesis::CI::GithubActions

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
