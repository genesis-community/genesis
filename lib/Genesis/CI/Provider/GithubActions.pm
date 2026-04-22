package Genesis::CI::Provider::GithubActions;
use strict;
use warnings;

use base 'Genesis::CI::Provider';
use Genesis;
use Genesis::UI;

use constant {
	DEFAULT_BRANCH => 'main',
};

### Class Methods {{{

# init - create a new GithubActions provider from CLI options {{{
sub init {
	my ($class, %opts) = @_;

	bail("GitHub Actions CI provider requires --ci-github-repo (format: org/repo)")
		unless $opts{'ci-github-repo'};

	bail("--ci-github-repo must be in 'org/repo' format")
		unless $opts{'ci-github-repo'} =~ m{^[^/]+/[^/]+$};

	$class->new(
		type   => 'github-actions',
		repo   => $opts{'ci-github-repo'},
		branch => $opts{'ci-github-branch'} || DEFAULT_BRANCH,
	);
}

# }}}
# new - create a GithubActions provider from stored config {{{
sub new {
	my ($class, %config) = @_;
	bless({
		label  => 'GitHub Actions',
		repo   => $config{repo},
		branch => $config{branch} || DEFAULT_BRANCH,
	}, $class);
}

# }}}
# opts - Getopt::Long spec for GitHub Actions-specific CLI flags {{{
sub opts {
	qw/
		ci-github-repo=s
		ci-github-branch=s
	/;
}

# }}}
# opts_help - usage documentation for GitHub Actions options {{{
sub opts_help {
	my ($class, %config) = @_;
	return '' unless grep { $_ eq 'github-actions' } @{$config{valid_types} || []};

	<<'EOF';
  CI Provider `github-actions`:

    --ci-github-repo <org/repo> (required)
        The GitHub repository to configure workflows for, in "org/repo"
        format (e.g. "myorg/my-deployment-repo").

    --ci-github-branch <branch> (optional, defaults to "main")
        The branch that workflow dispatch events and pushes will trigger
        pipeline runs on.  Defaults to "main".

EOF
}

# }}}
# }}}
### Instance Methods {{{

# label - human-readable name for this provider {{{
sub label { 'GitHub Actions' }

# }}}
# validate_config - assert required fields are present in stored config {{{
sub validate_config {
	my ($self) = @_;
	my @errors;
	push @errors, "'repo' is required for the GitHub Actions provider"
		unless $self->{repo};
	push @errors, "'repo' must be in 'org/repo' format"
		if $self->{repo} && $self->{repo} !~ m{^[^/]+/[^/]+$};
	return @errors;
}

# }}}
# config - returns hash for .genesis/config ci.provider section {{{
sub config {
	my ($self) = @_;
	my %cfg = (type => 'github-actions');
	$cfg{repo}   = $self->{repo}   if defined $self->{repo};
	$cfg{branch} = $self->{branch} if defined $self->{branch} && $self->{branch} ne DEFAULT_BRANCH;
	return %cfg;
}

# }}}
# interactive_wizard - prompt user for GitHub Actions configuration {{{
sub interactive_wizard {
	my ($self, $top, %opts) = @_;

	my $repo = $opts{'ci-github-repo'};
	unless ($repo && $repo =~ m{^[^/]+/[^/]+$}) {
		$repo = prompt_for_line(undef,
			"GitHub repository (org/repo format): ", '');
		bail("GitHub Actions CI provider requires a repository")
			unless $repo && $repo =~ /\S/;
		bail("Repository must be in 'org/repo' format")
			unless $repo =~ m{^[^/]+/[^/]+$};
	}

	my $branch;
	if (exists $opts{'ci-github-branch'}) {
		$branch = $opts{'ci-github-branch'} || DEFAULT_BRANCH;
	} else {
		$branch = prompt_for_line(undef,
			sprintf("Default branch [%s]: ", DEFAULT_BRANCH), DEFAULT_BRANCH);
		$branch = DEFAULT_BRANCH unless $branch && $branch =~ /\S/;
	}

	return $self->new(
		type   => 'github-actions',
		repo   => $repo,
		branch => $branch,
	);
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Provider::GithubActions - GitHub Actions CI provider for Genesis repo-init

=head1 DESCRIPTION

Manages GitHub Actions-specific CI configuration in .genesis/config ci.provider.

=head1 SYNOPSIS

  my $p = Genesis::CI::Provider::GithubActions->init(
    'ci-github-repo'   => 'myorg/my-deployment',
    'ci-github-branch' => 'main',
  );
  my %cfg = $p->config;
  # { type => 'github-actions', repo => 'myorg/my-deployment' }

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
