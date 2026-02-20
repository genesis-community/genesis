package Genesis::CI::GithubActions;
use v5.20;
use warnings;

use parent 'Genesis::CI';

use Genesis;
use Genesis::Top;
use YAML::PP;

### Class Methods {{{

# init - initialize GitHub Actions provider {{{
sub init {
	my ($class, %opts) = @_;
	
	my $self = bless({
		file   => $opts{file},
		top    => $opts{top},
		config => undef,
		errors => [],
	}, $class);
	
	return $self;
}

# }}}
# }}}
### Trait Interface Implementation {{{

# parse - parse and validate GitHub Actions workflow configuration {{{
sub parse {
	my ($self) = @_;
	
	bail("CI configuration file not specified") unless $self->{file};
	bail("CI configuration file '%s' not found", $self->{file})
		unless -f $self->{file};
	
	# Load configuration using spruce
	my $yaml = load_yaml(run({
		onfailure => "Failed to evaluate CI configuration file ".$self->{file},
		stderr    => 0
	}, 'spruce', 'merge', $self->{file}));
	
	# Validate top-level structure
	my @errors;
	unless (exists $yaml->{pipeline}) {
		push @errors, "Missing top-level 'pipeline:' key.";
	}
	
	unless (ref($yaml->{pipeline}) eq 'HASH') {
		push @errors, "Top-level 'pipeline:' key must be a map.";
	}
	
	if (@errors) {
		$self->{errors} = \@errors;
		bail("Configuration validation failed:\n  %s", join("\n  ", @errors));
	}
	
	# Validate required keys
	for (qw(name vault git boshes)) {
		unless ($yaml->{pipeline}{$_}) {
			push @errors, "`pipeline.$_' is required.";
		}
	}
	
	if (@errors) {
		$self->{errors} = \@errors;
		bail("Configuration validation failed:\n  %s", join("\n  ", @errors));
	}
	
	$self->{config} = $yaml->{pipeline};
	
	# Normalize git configuration
	$self->_normalize_git_config();
	
	# Normalize vault configuration
	$self->_normalize_vault_config();
	
	# Determine environments and trigger order
	$self->_determine_environments();
	
	return $self;
}

# }}}
# generate - generate GitHub Actions workflow YAML {{{
sub generate {
	my ($self) = @_;
	
	bail("Must call parse() before generate()") unless $self->{config};
	
	my $workflow = {
		name => $self->{config}{name},
		on   => $self->_generate_triggers(),
		jobs => $self->_generate_jobs(),
	};
	
	# Convert to YAML
	my $ypp = YAML::PP->new;
	return $ypp->dump_string($workflow);
}

# }}}
# deploy - deploy workflow to GitHub {{{
sub deploy {
	my ($self, %opts) = @_;
	
	bail("Must call parse() before deploy()") unless $self->{config};
	
	my $dry_run = $opts{'dry-run'};
	my $yaml = $self->generate();
	
	if ($dry_run) {
		output({raw => 1}, $yaml);
		return;
	}
	
	# Write to .github/workflows/ directory
	my $git_root = $self->{config}{git}{root} || '.';
	my $workflow_dir = "$git_root/.github/workflows";
	my $workflow_file = "$workflow_dir/".$self->{config}{name}.".yml";
	
	# Create directory if needed
	mkdir_or_fail($workflow_dir) unless -d $workflow_dir;
	
	# Write workflow file
	mkfile_or_fail($workflow_file, $yaml);
	
	info(
		"GitHub Actions workflow written to: %s\n".
		"Commit and push this file to enable the workflow.",
		$workflow_file
	);
	
	return;
}

# }}}
# platform_name - return platform name {{{
sub platform_name {
	return "GitHub Actions";
}

# }}}
# file_extension - return file extension {{{
sub file_extension {
	return ".yml";
}

# }}}
# }}}
### Internal GitHub Actions-Specific Methods {{{

# _normalize_git_config - normalize git configuration {{{
sub _normalize_git_config {
	my ($self) = @_;
	my $git = $self->{config}{git};
	
	# Set defaults
	$git->{branch} ||= 'master';
	$git->{root} ||= '.';
	$git->{root} =~ s#/*$##;
	
	# Determine repository from URI if not specified
	if ($git->{uri} && !$git->{owner} && !$git->{repo}) {
		# Parse git@github.com:owner/repo or https://github.com/owner/repo.git
		if ($git->{uri} =~ m{(?:git@|https?://)[^/:]+[:/]([^/]+)/([^/]+?)(?:\.git)?$}) {
			$git->{owner} = $1;
			$git->{repo} = $2;
		}
	}
	
	return;
}

# }}}
# _normalize_vault_config - normalize vault configuration {{{
sub _normalize_vault_config {
	my ($self) = @_;
	my $vault = $self->{config}{vault};
	
	# GitHub Actions will use secrets for vault credentials
	# No spruce operators needed here
	
	return;
}

# }}}
# _determine_environments - determine deployment environments and order {{{
sub _determine_environments {
	my ($self) = @_;
	
	my @envs = sort keys %{$self->{config}{boshes}};
	$self->{environments} = \@envs;
	
	# TODO: Determine trigger order based on layout
	# For now, just use alphabetical order
	
	return;
}

# }}}
# _generate_triggers - generate workflow triggers {{{
sub _generate_triggers {
	my ($self) = @_;
	
	return {
		push => {
			branches => [$self->{config}{git}{branch}],
			paths    => [$self->{config}{git}{root} . '/**'],
		},
		workflow_dispatch => undef,  # Manual trigger
	};
}

# }}}
# _generate_jobs - generate workflow jobs {{{
sub _generate_jobs {
	my ($self) = @_;
	
	my %jobs;
	
	# Generate a job for each environment
	for my $env (@{$self->{environments}}) {
		my $alias = $self->{config}{boshes}{$env}{alias} || $env;
		
		$jobs{"deploy-$alias"} = {
			'runs-on' => 'ubuntu-latest',
			steps     => $self->_generate_steps_for_env($env),
		};
	}
	
	return \%jobs;
}

# }}}
# _generate_steps_for_env - generate deployment steps for an environment {{{
sub _generate_steps_for_env {
	my ($self, $env) = @_;
	
	my @steps;
	
	# Checkout code
	push @steps, {
		name => 'Checkout code',
		uses => 'actions/checkout@v4',
	};
	
	# Vault authentication
	push @steps, {
		name => 'Authenticate to Vault',
		uses => 'hashicorp/vault-action@v2',
		with => {
			url    => $self->{config}{vault}{url},
			method => 'approle',
			roleId => '${{ secrets.VAULT_ROLE_ID }}',
			secretId => '${{ secrets.VAULT_SECRET_ID }}',
		},
	};
	
	# Genesis deploy
	push @steps, {
		name => "Deploy $env",
		run  => "genesis deploy $env",
		env  => {
			BOSH_ENVIRONMENT => $self->{config}{boshes}{$env}{url} || '${{ secrets.BOSH_ENVIRONMENT }}',
			BOSH_CA_CERT     => $self->{config}{boshes}{$env}{ca_cert} || '${{ secrets.BOSH_CA_CERT }}',
			BOSH_CLIENT      => $self->{config}{boshes}{$env}{username} || '${{ secrets.BOSH_CLIENT }}',
			BOSH_CLIENT_SECRET => $self->{config}{boshes}{$env}{password} || '${{ secrets.BOSH_CLIENT_SECRET }}',
		},
	};
	
	# Notifications (if configured)
	if ($self->{config}{slack}) {
		push @steps, {
			name => 'Notify Slack',
			if   => 'always()',
			uses => 'slackapi/slack-github-action@v1',
			with => {
				channel_id => $self->{config}{slack}{channel},
				slack_message => "Deployment to $env " . '${{ job.status }}',
			},
			env => {
				SLACK_BOT_TOKEN => '${{ secrets.SLACK_BOT_TOKEN }}',
			},
		};
	}
	
	return \@steps;
}

# }}}
# }}}
### Accessors {{{

# config - get parsed configuration {{{
sub config {
	return $_[0]->{config};
}

# }}}
# top - get Genesis::Top object {{{
sub top {
	return $_[0]->{top};
}

# }}}
# environments - get list of environments {{{
sub environments {
	return @{$_[0]->{environments} || []};
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::GithubActions - GitHub Actions provider implementation

=head1 DESCRIPTION

Genesis::CI::GithubActions implements the Genesis::CI trait interface for
GitHub Actions. It handles parsing ci.yml configuration, generating GitHub
Actions workflow YAML, and writing workflow files to .github/workflows/.

This is a complete, self-contained implementation that does not share code
with Concourse or other providers.

=head1 SYNOPSIS

  use Genesis::CI;
  
  my $ci = Genesis::CI->new(
    type => 'github-actions',
    file => 'ci.yml',
    top  => $top_obj
  );
  
  $ci->parse();
  my $yaml = $ci->generate();
  $ci->deploy(dry-run => 0);

=head1 TRAIT INTERFACE METHODS

=head2 init(%opts)

Initialize GitHub Actions provider instance.

=head2 parse()

Parse and validate ci.yml configuration for GitHub Actions.

=head2 generate()

Generate GitHub Actions workflow YAML.

=head2 deploy(%opts)

Write workflow file to .github/workflows/ directory.

Options: dry-run

=head2 platform_name()

Returns "GitHub Actions".

=head2 file_extension()

Returns ".yml".

=head1 ACCESSORS

=head2 config()

Returns parsed pipeline configuration.

=head2 top()

Returns Genesis::Top object.

=head2 environments()

Returns list of deployment environments.

=head1 SEE ALSO

Genesis::CI, Genesis::CI::Concourse, Genesis::CI::Legacy

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
