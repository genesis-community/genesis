package Genesis::CI::Concourse;
use v5.20;
use warnings;

use parent 'Genesis::CI';

use Genesis;
use Genesis::Top;
use Genesis::CI::Legacy;

### Class Methods {{{

# init - initialize Concourse provider {{{
sub init {
	my ($class, %opts) = @_;
	
	my $self = bless({
		file   => $opts{file},
		top    => $opts{top},
		layout => $opts{layout},
		config => undef,
		errors => [],
	}, $class);
	
	return $self;
}

# }}}
# }}}
### Trait Interface Implementation {{{

# parse - parse and validate Concourse pipeline configuration {{{
sub parse {
	my ($self) = @_;
	
	# Delegate to Legacy implementation for now
	# This validates and normalizes the config
	my ($pipeline, $layout) = Genesis::CI::Legacy::parse(
		$self->{file},
		$self->{top},
		$self->{layout}
	);
	
	$self->{config} = $pipeline;
	$self->{layout} = $layout;
	
	return $self;
}

# }}}
# generate - generate Concourse pipeline YAML {{{
sub generate {
	my ($self) = @_;
	
	bail("Must call parse() before generate()") unless $self->{config};
	
	# Delegate to Legacy implementation
	# TODO: Refactor Legacy logic into this class over time
	my $yaml = Genesis::CI::Legacy::generate_pipeline_concourse_yaml(
		$self->{config},
		$self->{top}
	);
	
	return $yaml;
}

# }}}
# deploy - deploy pipeline to Concourse via fly CLI {{{
sub deploy {
	my ($self, %opts) = @_;
	
	my $target = $opts{target} || $self->{layout};
	my $pipeline_name = $self->{config}{pipeline}{name};
	my $dry_run = $opts{'dry-run'};
	my $yes = $opts{yes};
	my $paused = $opts{paused};
	
	bail("Must call parse() before deploy()") unless $self->{config};
	
	my $yaml = $self->generate();
	
	if ($dry_run) {
		output({raw => 1}, $yaml);
		return;
	}
	
	# Pause pipeline before updating
	my ($out, $rc) = run(
		'fly -t $1 pause-pipeline -p $2',
		$target, $pipeline_name
	);
	bail("Could not pause pipeline '%s': %s", $pipeline_name, $out)
		unless $rc == 0 || $out =~ /pipeline '.*' not found/;
	
	# Write pipeline to temp file
	my $dir = workdir;
	mkfile_or_fail("${dir}/pipeline.yml", $yaml);
	
	# Upload pipeline
	my $yes_flag = $yes ? '-n' : '';
	run({
		interactive => 1,
		onfailure => "Could not upload pipeline $pipeline_name"
	},
		'fly -t $1 set-pipeline '.$yes_flag.' -p $2 -c $3/pipeline.yml',
		$target, $pipeline_name, $dir
	);
	
	# Unpause pipeline (unless --paused)
	unless ($paused) {
		run({
			interactive => 1,
			onfailure => "Could not unpause pipeline $pipeline_name"
		},
			'fly -t $1 unpause-pipeline -p $2',
			$target, $pipeline_name
		);
	}
	
	# Set visibility (public/private)
	my $action = $self->{config}{pipeline}{public} ? 'expose' : 'hide';
	run({
		interactive => 1,
		onfailure => "Could not $action pipeline $pipeline_name"
	},
		'fly -t $1 '.$action.'-pipeline -p $2',
		$target, $pipeline_name
	);
	
	return;
}

# }}}
# platform_name - return platform name {{{
sub platform_name {
	return "Concourse";
}

# }}}
# file_extension - return file extension {{{
sub file_extension {
	return ".yml";
}

# }}}
# }}}
### Additional Concourse-Specific Methods {{{

# graphviz - generate graphviz dot source {{{
sub graphviz {
	my ($self) = @_;
	
	bail("Must call parse() before graphviz()") unless $self->{config};
	
	return Genesis::CI::Legacy::generate_pipeline_graphviz_source(
		$self->{config}
	);
}

# }}}
# describe - generate human-readable description {{{
sub describe {
	my ($self) = @_;
	
	bail("Must call parse() before describe()") unless $self->{config};
	
	Genesis::CI::Legacy::generate_pipeline_human_description(
		$self->{config}
	);
	
	return;
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
# layout - get layout name {{{
sub layout {
	return $_[0]->{layout};
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Concourse - Concourse CI provider implementation

=head1 DESCRIPTION

Genesis::CI::Concourse implements the Genesis::CI trait interface for
Concourse CI. It handles parsing ci.yml configuration, generating Concourse
pipeline YAML, and deploying pipelines via the fly CLI.

This implementation currently delegates to Genesis::CI::Legacy for the heavy
lifting, but provides a clean interface for future refactoring.

=head1 SYNOPSIS

  use Genesis::CI;
  
  my $ci = Genesis::CI->new(
    type   => 'concourse',
    file   => 'ci.yml',
    top    => $top_obj,
    layout => 'default'
  );
  
  $ci->parse();
  my $yaml = $ci->generate();
  $ci->deploy(target => 'prod', yes => 1);

=head1 TRAIT INTERFACE METHODS

=head2 init(%opts)

Initialize Concourse provider instance.

=head2 parse()

Parse and validate ci.yml configuration for Concourse.

=head2 generate()

Generate Concourse pipeline YAML.

=head2 deploy(%opts)

Deploy pipeline to Concourse via fly CLI.

Options: target, dry-run, yes, paused

=head2 platform_name()

Returns "Concourse".

=head2 file_extension()

Returns ".yml".

=head1 CONCOURSE-SPECIFIC METHODS

=head2 graphviz()

Generate Graphviz DOT source for pipeline visualization.

=head2 describe()

Print human-readable pipeline description to stdout.

=head1 ACCESSORS

=head2 config()

Returns parsed pipeline configuration.

=head2 top()

Returns Genesis::Top object.

=head2 layout()

Returns layout name.

=head1 SEE ALSO

Genesis::CI, Genesis::CI::GithubActions, Genesis::CI::Legacy

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
