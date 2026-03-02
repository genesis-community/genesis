package Genesis::CI::Compiler::ScriptDiscovery;
use strict;
use warnings;

use Genesis;

### Constructor {{{

# new - create a new script discovery instance {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		repo_path => $opts{repo_path} || '.',
	}, $class);
}

# }}}
# }}}
### Public Methods {{{

# discover - discover and validate scripts from all sources {{{
sub discover {
	my ($self, $parsed_config) = @_;

	my %scripts;

	# 1. Load from explicit manifest (highest priority)
	my $manifest_data = $parsed_config->{scripts} || {};
	my $manifest_scripts = $manifest_data->{scripts} || $manifest_data;
	if (ref($manifest_scripts) eq 'HASH' && %$manifest_scripts) {
		my $loaded = $self->_load_manifest($manifest_scripts);
		%scripts = (%scripts, %$loaded);
	}

	# 2. Auto-discover scripts with inline metadata
	my @script_dirs = ("$self->{repo_path}/scripts", "$self->{repo_path}/.genesis/ci/scripts");
	for my $dir (@script_dirs) {
		next unless -d $dir;
		for my $file (glob("$dir/*.sh"), glob("$dir/**/*.sh")) {
			next unless -f $file;

			# Skip if already loaded from manifest
			my $rel_path = $file;
			$rel_path =~ s{^\Q$self->{repo_path}\E/}{};
			next if grep { ($scripts{$_}{path} || '') eq $rel_path } keys %scripts;

			my $metadata = $self->_extract_inline_metadata($file);
			if ($metadata) {
				$metadata->{path} = $rel_path;
				my $id = $metadata->{id} || $self->_path_to_id($rel_path);
				$metadata->{id} = $id;
				$scripts{$id} = $metadata;
			}
		}
	}

	# 3. Convention-based defaults for undiscovered scripts
	for my $dir (@script_dirs) {
		next unless -d $dir;
		for my $file (glob("$dir/*.sh"), glob("$dir/**/*.sh")) {
			next unless -f $file;

			my $rel_path = $file;
			$rel_path =~ s{^\Q$self->{repo_path}\E/}{};

			# Skip if already discovered
			next if grep {
				($scripts{$_}{path} || '') eq $rel_path
			} keys %scripts;

			my $metadata = $self->_infer_metadata($file, $rel_path);
			if ($metadata) {
				my $id = $metadata->{id};
				$scripts{$id} = $metadata;
			}
		}
	}

	# Validate all discovered scripts
	for my $id (keys %scripts) {
		$self->_validate_script($id, $scripts{$id});
	}

	return \%scripts;
}

# }}}
# }}}
### Internal Methods {{{

# _load_manifest - load scripts from manifest data {{{
sub _load_manifest {
	my ($self, $manifest) = @_;

	my %scripts;
	for my $id (keys %$manifest) {
		my $entry = $manifest->{$id};
		next unless ref($entry) eq 'HASH';

		$scripts{$id} = {
			id          => $id,
			description => $entry->{description} || '',
			path        => $entry->{path} || '',
			executor    => $entry->{executor} || 'bash',
			version     => $entry->{version} || '1.0',
			requirements => $entry->{requirements} || [],
			inputs       => $entry->{inputs} || [],
			outputs      => $entry->{outputs} || [],
			environment  => {
				required => $entry->{environment}{required} || [],
				optional => $entry->{environment}{optional} || [],
			},
			timeout      => $entry->{timeout},
			exit_codes   => $entry->{exit_codes} || {},
			privileged   => $entry->{privileged} || 0,
		};
	}

	return \%scripts;
}

# }}}
# _extract_inline_metadata - parse @genesis-script annotations {{{
sub _extract_inline_metadata {
	my ($self, $file) = @_;

	open my $fh, '<', $file or return undef;

	my %metadata;
	my $found_marker = 0;

	while (my $line = <$fh>) {
		chomp $line;

		# Look for the @genesis-script marker
		if ($line =~ /^\s*#\s*\@genesis-script\s*$/) {
			$found_marker = 1;
			next;
		}

		# Only parse annotations after the marker (or if we find annotations without it)
		if ($line =~ /^\s*#\s*\@(\w[\w-]*)\s*:\s*(.*)$/) {
			$found_marker = 1;
			my ($key, $value) = ($1, $2);
			$value =~ s/\s+$//;

			if ($key eq 'description') {
				$metadata{description} = $value;
			} elsif ($key eq 'version') {
				$metadata{version} = $value;
			} elsif ($key eq 'requires') {
				$metadata{requirements} ||= [];
				for my $req (split /\s*,\s*/, $value) {
					if ($req =~ /^([\w-]+)(.*)$/) {
						push @{$metadata{requirements}}, {
							tool    => $1,
							version => $2 || '',
						};
					}
				}
			} elsif ($key eq 'input') {
				$metadata{inputs} ||= [];
				if ($value =~ /^(\S+)\s*\(([^)]+)\)/) {
					my ($name, $attrs) = ($1, $2);
					my ($type, $required) = split /\s*,\s*/, $attrs;
					push @{$metadata{inputs}}, {
						name     => $name,
						type     => $type || 'file',
						required => ($required && $required eq 'required') ? 1 : 0,
					};
				}
			} elsif ($key eq 'output') {
				$metadata{outputs} ||= [];
				if ($value =~ /^(\S+)\s*\(([^,]+),\s*(.+)\)/) {
					push @{$metadata{outputs}}, {
						name => $1,
						type => $2,
						path => $3,
					};
				}
			} elsif ($key =~ /^env-required$/) {
				$metadata{environment}{required} = [split /\s*,\s*/, $value];
			} elsif ($key =~ /^env-optional$/) {
				$metadata{environment}{optional} = [split /\s*,\s*/, $value];
			} elsif ($key eq 'timeout') {
				$metadata{timeout} = $value;
			} elsif ($key eq 'privileged') {
				$metadata{privileged} = ($value =~ /^(true|yes|1)$/i) ? 1 : 0;
			}
		} elsif ($found_marker && $line !~ /^\s*#/) {
			# Stop parsing at first non-comment line after annotations
			last;
		}
	}
	close $fh;

	return $found_marker ? \%metadata : undef;
}

# }}}
# _infer_metadata - infer metadata from filename conventions {{{
sub _infer_metadata {
	my ($self, $file, $rel_path) = @_;

	my $id = $self->_path_to_id($rel_path);

	# Infer description from filename
	(my $desc = $id) =~ s{[/_-]}{\ }g;
	$desc = ucfirst($desc);

	return {
		id          => $id,
		description => $desc,
		path        => $rel_path,
		executor    => 'bash',
		version     => '1.0',
		requirements => [],
		inputs       => [{
			name     => 'deployment-repo',
			type     => 'git-repository',
			required => 1,
		}],
		outputs      => [],
		environment  => {
			required => [],
			optional => [],
		},
		timeout      => undef,
		exit_codes   => { 0 => 'success', 1 => 'error' },
	};
}

# }}}
# _path_to_id - convert a file path to a script ID {{{
sub _path_to_id {
	my ($self, $path) = @_;

	# Remove scripts/ prefix and .sh extension
	(my $id = $path) =~ s{^(?:\.genesis/ci/)?scripts/}{};
	$id =~ s{\.sh$}{};

	return $id;
}

# }}}
# _validate_script - validate script metadata completeness {{{
sub _validate_script {
	my ($self, $id, $script) = @_;

	# Ensure required fields
	$script->{id}          ||= $id;
	$script->{executor}    ||= 'bash';
	$script->{version}     ||= '1.0';
	$script->{requirements} ||= [];
	$script->{inputs}       ||= [];
	$script->{outputs}      ||= [];
	$script->{environment}  ||= {};
	$script->{environment}{required} ||= [];
	$script->{environment}{optional} ||= [];
	$script->{exit_codes}   ||= {};

	# Check that the script file exists if path is specified
	if ($script->{path} && $self->{repo_path}) {
		my $full_path = "$self->{repo_path}/$script->{path}";
		unless (-f $full_path) {
			debug("Script '$id' references non-existent file: %s", $full_path);
		}
	}
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler::ScriptDiscovery - Script metadata discovery

=head1 DESCRIPTION

Genesis::CI::Compiler::ScriptDiscovery discovers and validates script
metadata from three sources (in priority order):

  1. Explicit manifest (scripts/manifest.yml)
  2. Inline metadata (@genesis-script annotations in script files)
  3. Convention-based inference from filename and location

=head1 SYNOPSIS

  my $discovery = Genesis::CI::Compiler::ScriptDiscovery->new(
    repo_path => '/path/to/repo',
  );

  my $scripts = $discovery->discover($parsed_config);
  # Returns: { 'deploy/genesis-deploy' => { ... }, ... }

=head1 INLINE ANNOTATIONS

Scripts can embed metadata using comments:

  #!/bin/bash
  # @genesis-script
  # @description: Execute Genesis deployment
  # @version: 1.0
  # @requires: genesis-cli>=3.1.0, bosh-cli>=7.0
  # @input: deployment-repo (git-repository, required)
  # @output: manifests (directory, .genesis/manifests/)
  # @env-required: CURRENT_ENV, VAULT_ADDR
  # @env-optional: GENESIS_TRACE
  # @timeout: 60m

=head1 SEE ALSO

Genesis::CI::Compiler::Parser, Genesis::CI::Compiler::ASTBuilder

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
