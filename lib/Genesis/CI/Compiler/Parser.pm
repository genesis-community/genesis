package Genesis::CI::Compiler::Parser;
use strict;
use warnings;

use Genesis;
use JSON::PP;

### Constructor {{{

# new - create a new parser instance {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		ci_dir => $opts{ci_dir},
		file   => $opts{file},
		top    => $opts{top},
	}, $class);
}

# }}}
# }}}
### Public Methods {{{

# parse - load and merge all configuration files {{{
sub parse {
	my ($self) = @_;

	# Determine parsing mode: multi-file (.genesis/ci/) or legacy single file
	if ($self->{ci_dir} && -d $self->{ci_dir}) {
		return $self->_parse_multi_file($self->{ci_dir});
	} elsif ($self->{file} && -f $self->{file}) {
		return $self->_parse_legacy_file($self->{file});
	} elsif ($self->{ci_dir}) {
		bail("CI configuration directory '%s' not found", $self->{ci_dir});
	} elsif ($self->{file}) {
		bail("CI configuration file '%s' not found", $self->{file});
	} else {
		bail("No CI configuration file or directory specified");
	}
}

# }}}
# }}}
### Multi-File Parser {{{

# _parse_multi_file - parse .genesis/ci/ directory structure {{{
sub _parse_multi_file {
	my ($self, $ci_dir) = @_;

	my %parsed;

	# Load pipeline.yml (required)
	my $pipeline_file = "$ci_dir/pipeline.yml";
	bail("Missing required '%s'", $pipeline_file) unless -f $pipeline_file;
	$parsed{pipeline} = $self->_load_yaml_file($pipeline_file);

	# Load targets.yml (required)
	my $targets_file = "$ci_dir/targets.yml";
	bail("Missing required '%s'", $targets_file) unless -f $targets_file;
	$parsed{targets} = $self->_load_yaml_file($targets_file);

	# Load integrations.yml (required)
	my $integrations_file = "$ci_dir/integrations.yml";
	bail("Missing required '%s'", $integrations_file) unless -f $integrations_file;
	$parsed{integrations} = $self->_load_yaml_file($integrations_file);

	# Load scripts/manifest.yml (optional)
	my $scripts_file = "$ci_dir/scripts/manifest.yml";
	if (-f $scripts_file) {
		$parsed{scripts} = $self->_load_yaml_file($scripts_file);
	} else {
		$parsed{scripts} = {};
	}

	# Load provider-config/*.yml (optional)
	$parsed{provider_config} = {};
	my $provider_dir = "$ci_dir/provider-config";
	if (-d $provider_dir) {
		for my $file (glob("$provider_dir/*.yml")) {
			(my $name = $file) =~ s{.*/}{};
			$name =~ s{\.yml$}{};
			$parsed{provider_config}{$name} = $self->_load_yaml_file($file);
		}
	}

	# Store source format for downstream use
	$parsed{_source_format} = 'multi-file';
	$parsed{_source_path}   = $ci_dir;

	return \%parsed;
}

# }}}
# }}}
### Legacy Single-File Parser {{{

# _parse_legacy_file - parse old-style single ci.yml and normalize {{{
sub _parse_legacy_file {
	my ($self, $file) = @_;

	my $raw = $self->_load_yaml_file($file);

	bail("Missing top-level 'pipeline:' key in %s", $file)
		unless exists $raw->{pipeline};
	bail("Top-level 'pipeline:' key must be a map in %s", $file)
		unless ref($raw->{pipeline}) eq 'HASH';

	my $p = $raw->{pipeline};

	# Normalize into multi-file structure
	my %parsed;

	# Pipeline section: metadata + workflows + layout
	$parsed{pipeline} = {
		metadata => {
			name    => $p->{name},
			version => '1.0',
		},
		branches => {
			live          => $p->{git}{branch} || 'master',
			target_prefix => 'target/',
		},
	};

	# Extract layout/layouts into workflows
	$parsed{pipeline}{workflows} = $self->_normalize_legacy_layouts($p);

	# Configuration section (global settings)
	$parsed{pipeline}{configuration} = {};
	$parsed{pipeline}{configuration}{public}     = $p->{public}     if exists $p->{public};
	$parsed{pipeline}{configuration}{tagged}     = $p->{tagged}     if exists $p->{tagged};
	$parsed{pipeline}{configuration}{unredacted} = $p->{unredacted} if exists $p->{unredacted};
	$parsed{pipeline}{configuration}{ocfp}       = $p->{ocfp}       if exists $p->{ocfp};
	$parsed{pipeline}{configuration}{debug}       = $p->{debug}      if exists $p->{debug};

	if ($p->{notifications}) {
		$parsed{pipeline}{configuration}{notifications} = {
			style => $p->{notifications},
		};
	}
	if ($p->{groups}) {
		$parsed{pipeline}{configuration}{groups} = $p->{groups};
	}
	if ($p->{errands}) {
		$parsed{pipeline}{configuration}{errands} = $p->{errands};
	}
	if ($p->{'auto-update'}) {
		$parsed{pipeline}{configuration}{auto_update} = $p->{'auto-update'};
	}
	if ($p->{'require-passed-caches'}) {
		$parsed{pipeline}{configuration}{'require-passed-caches'} = $p->{'require-passed-caches'};
	}

	# Task configuration
	$parsed{pipeline}{configuration}{task} = $p->{task} || {};

	# Registry configuration
	$parsed{pipeline}{configuration}{registry} = $p->{registry} if $p->{registry};

	# Targets section: normalize boshes into targets format
	$parsed{targets} = $self->_normalize_legacy_boshes($p->{boshes} || {});

	# Integrations section: extract vault, git, notifications, locker
	$parsed{integrations} = $self->_normalize_legacy_integrations($p);

	# Scripts section: empty for legacy format (handled internally by Legacy)
	$parsed{scripts} = {};

	# Provider config: empty for legacy
	$parsed{provider_config} = {};

	# Store source info
	$parsed{_source_format} = 'legacy';
	$parsed{_source_path}   = $file;

	# Keep raw legacy data for providers that need it
	$parsed{_legacy_raw} = $raw;

	return \%parsed;
}

# }}}
# _normalize_legacy_boshes - convert boshes map to targets format {{{
sub _normalize_legacy_boshes {
	my ($self, $boshes) = @_;

	my %targets;
	for my $env_name (keys %$boshes) {
		my $bosh = $boshes->{$env_name};

		my $target = {
			name  => $env_name,
			alias => $bosh->{alias} || $env_name,
			tags  => [],
		};

		if ($bosh->{url}) {
			# Standard BOSH director
			$target->{type} = 'bosh-director';
			$target->{connection} = {
				url  => $bosh->{url},
				auth => {
					type          => 'basic',
					client_id     => $bosh->{username},
					client_secret => $bosh->{password},
				},
				ca_cert => $bosh->{ca_cert},
			};
		} else {
			# Create-env (proto-BOSH)
			$target->{type} = 'bosh-create-env';
			push @{$target->{tags}}, 'create-env';
		}

		if ($bosh->{genesis_env}) {
			$target->{genesis_env} = $bosh->{genesis_env};
		}

		$targets{$env_name} = $target;
	}

	return { targets => \%targets };
}

# }}}
# _normalize_legacy_integrations - extract integrations from legacy config {{{
sub _normalize_legacy_integrations {
	my ($self, $p) = @_;

	my %integrations;

	# Vault
	if ($p->{vault}) {
		$integrations{vault} = {
			url       => $p->{vault}{url},
			namespace => $p->{vault}{namespace},
			auth      => {
				type      => 'approle',
				role_id   => $p->{vault}{role},
				secret_id => $p->{vault}{secret},
			},
			options => {
				tls_verify => $p->{vault}{verify} // 1,
			},
		};
		if ($p->{vault}{'no-strongbox'}) {
			$integrations{vault}{options}{no_strongbox} = 1;
		}
	}

	# Git / source control
	if ($p->{git}) {
		my $git = $p->{git};
		$integrations{source_control} = {
			repository     => ($git->{owner} && $git->{repo})
				? "$git->{owner}/$git->{repo}" : '',
			uri            => $git->{uri},
			default_branch => $git->{branch} || 'master',
			root           => $git->{root} || '.',
			version_depth  => $git->{version_depth} || 0,
			commit_author  => {
				name  => ($git->{commits} ? $git->{commits}{user_name} : undef) || 'Concourse Bot',
				email => ($git->{commits} ? $git->{commits}{user_email} : undef) || 'concourse@pipeline',
			},
		};

		if ($git->{private_key}) {
			$integrations{source_control}{auth} = {
				type        => 'ssh-key',
				private_key => $git->{private_key},
			};
		} elsif ($git->{username}) {
			$integrations{source_control}{auth} = {
				type     => 'username-password',
				username => $git->{username},
				password => $git->{password},
			};
		}
	}

	# Notifications
	my @notifications;
	if ($p->{slack}) {
		push @notifications, {
			type     => 'slack',
			name     => 'slack',
			webhook  => $p->{slack}{webhook},
			channel  => $p->{slack}{channel},
			username => $p->{slack}{username} || 'runwaybot',
			icon     => $p->{slack}{icon} || 'http://cl.ly/image/3e1h0H3H2s0P/concourse-logo.png',
			events   => ['started', 'failed', 'succeeded'],
		};
	}
	if ($p->{email}) {
		push @notifications, {
			type       => 'email',
			name       => 'email',
			recipients => $p->{email}{to},
			from       => $p->{email}{from},
			smtp       => $p->{email}{smtp},
			events     => ['failed'],
		};
	}
	$integrations{notifications} = \@notifications if @notifications;

	# Locker
	if ($p->{locker} && $p->{locker}{url}) {
		$integrations{locker} = {
			url                 => $p->{locker}{url},
			username            => $p->{locker}{username},
			password            => $p->{locker}{password},
			ca_cert             => $p->{locker}{ca_cert},
			skip_ssl_validation => $p->{locker}{skip_ssl_validation},
		};
	}

	return \%integrations;
}

# }}}
# _normalize_legacy_layouts - extract layout/layouts and parse DSL {{{
sub _normalize_legacy_layouts {
	my ($self, $p) = @_;

	# Normalize layout/layouts into a consistent structure
	my %layouts;
	if (exists $p->{layout} && exists $p->{layouts}) {
		bail("Both 'pipeline.layout' and 'pipeline.layouts' specified; pick one");
	} elsif (exists $p->{layout}) {
		$layouts{default} = $p->{layout};
	} elsif (exists $p->{layouts} && ref($p->{layouts}) eq 'HASH') {
		%layouts = %{$p->{layouts}};
	} else {
		bail("Missing 'pipeline.layout' or 'pipeline.layouts'");
	}

	# Parse each layout into workflow definitions
	my %workflows;
	for my $layout_name (keys %layouts) {
		my $src = $layouts{$layout_name};
		$workflows{$layout_name} = $self->_parse_layout_dsl($src, $p->{boshes} || {});
	}

	return \%workflows;
}

# }}}
# _parse_layout_dsl - parse the legacy layout DSL into structured form {{{
sub _parse_layout_dsl {
	my ($self, $src, $boshes) = @_;

	# Remove comments and collapse newlines (same as Legacy.pm lines 502-504)
	$src =~ s/\s*#.*$//gm;
	$src =~ s/[\r\n]+/ ; /g;
	$src =~ s/(^\s+|\s+$)//;

	# Tokenize into rules
	my @rules = ();
	my $rule  = [];
	for my $tok (split /\s+/, "$src ;") {
		next unless $tok;
		if ($tok eq ';') {
			push @rules, $rule if @$rule;
			$rule = [];
			next;
		}
		push @$rule, $tok;
	}

	# Process rules into auto patterns and trigger chains
	my @auto_patterns;
	my %envs;
	my %will_trigger;

	for $rule (@rules) {
		my ($cmd, @args) = @$rule;

		if ($cmd eq 'auto') {
			bail("The 'auto' directive requires at least one argument")
				unless @args;
			push @auto_patterns, @args;
			next;
		}

		# Must be a pipeline definition: env [ -> env]*
		unless ($boshes->{$cmd}) {
			bail("Unrecognized environment or configuration directive: '%s'", $cmd);
		}

		my $orig = join ' ', @$rule;
		my ($env, $token);
		while (@$rule) {
			($env, $token, @$rule) = @$rule;
			$envs{$env} = 1;
			if (defined($token)) {
				bail("Invalid pipeline definition '%s': expecting '<env> [-> <env>]...'", $orig)
					unless $token eq '->';
				my $target = $rule->[0];
				bail("Missing target after -> in pipeline definition '%s'", $orig)
					unless $target;
				push @{$will_trigger{$env}}, $target;
			}
		}
	}

	return {
		auto_patterns => \@auto_patterns,
		environments  => [keys %envs],
		will_trigger  => \%will_trigger,
		_raw_source   => $src,
	};
}

# }}}
# }}}
### Internal Helpers {{{

# _load_yaml_file - load and evaluate a YAML file via spruce merge {{{
sub _load_yaml_file {
	my ($self, $path) = @_;

	return load_yaml(run({
		onfailure => "Failed to evaluate configuration file $path",
		stderr    => 0,
	}, 'spruce', 'merge', $path));
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler::Parser - Multi-format CI configuration parser

=head1 DESCRIPTION

Genesis::CI::Compiler::Parser loads and normalizes CI configuration from
either the legacy single-file C<ci.yml> format or the new multi-file
C<.genesis/ci/> directory structure. Both formats are normalized into a
common intermediate structure for downstream processing.

=head1 SYNOPSIS

  # Parse new multi-file format
  my $parser = Genesis::CI::Compiler::Parser->new(
    ci_dir => '.genesis/ci',
    top    => $top_obj,
  );
  my $parsed = $parser->parse();

  # Parse legacy single-file format
  my $parser = Genesis::CI::Compiler::Parser->new(
    file => 'ci.yml',
    top  => $top_obj,
  );
  my $parsed = $parser->parse();

=head1 SEE ALSO

Genesis::CI::Compiler::Validator, Genesis::CI::Compiler::ASTBuilder

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
