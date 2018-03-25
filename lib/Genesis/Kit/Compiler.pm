package Genesis::Kit::Compiler;

use Genesis::Utils;
use Genesis::IO;
use Genesis::Run;

sub new {
	my ($class, $root) = @_;
	bless({
		root => $root,
		work => workdir(),
	}, $class);
}

sub validate {
	my ($self) = @_;

	my $rc = 1;
	if (!-d $self->{root}) {
		error "Kit source directory '$self->{root}' not found.";
		return 0;
	}

	#if (!-d "$self->{root}/hooks/") {
	#	error "No hooks/ directory found.";
	#	$rc = 0;
	#}

	for my $hook (qw(new secrets blueprint info addon)) {
		next unless -e "$self->{root}/hooks/$hook";
		if (!-f "$self->{root}/hooks/$hook") {
			error "Hook script hooks/$hook is not a regular file.";
			$rc = 0;
		} elsif (!-x "$self->{root}/hooks/$hook") {
			error "Hook script hooks/$hook is not executable.";
			$rc = 0;
		}
	}

	if (! -f "$self->{root}/kit.yml") {
		error "Kit Metadata file kit.yml does not exist.";
		$rc = 0;
	} else {
		my $meta = eval { LoadFile("$self->{root}/kit.yml") };
		if ($@) {
			error "Kit Metadata file kit.yml is not well-formed YAML: $@";
			$rc = 0;
		}
		for my $key (qw(name code)) {
			next if $meta->{$key};
			error "Kit Metadata file kit.yml does not define `$key'";
			$rc = 0;
		}
		if (!$meta->{author} && !$meta->{authors}) {
			error "Kit Metadata file kit.yml does not identify the author(s) via `author' or `authors'";
			$rc = 0;
		}
		if ($meta->{author} && $meta->{authors}) {
			error "Kit Metadata file kit.yml specifies both `author' and `authors': pick one.";
			$rc = 0;
		}

		# genesis versions must be semver
		if (exists $meta->{genesis_min_version}) {
			if (!is_semver($meta->{genesis_min_version})) {
				error "Kit Metadata specifies minimum Genesis version '$meta->{genesis_min_version}', which is not a semantic version (x.y.z).";
				$rc = 0;
			}
		}
	}

	return $rc;
}

sub _prepare {
	my ($self, $relpath) = @_;
	$self->{relpath} = $relpath;

	run(
		{ onfailure => 'Unable to set up a temporary working copy of the kit source files' },
		'rm -rf "$2/$3" && cp -a "$1" "$2/$3"',
		$self->{root}, $self->{work}, $self->{relpath});

	(my $out, undef) = run(
		{ onfailure => 'Unable to determine what files to clean up before compiling the kit' },
		'git -C "$1" clean -xdn', $self->{root});

	my @files = map { "$self->{work}/$self->{relpath}/$_" } qw(ci .git .gitignore);
	for (split /\s+/, $out) {
		s/^would remove //i;
		push @files, "$self->{work}/$self->{relpath}/$_";
	}
	run(
		{ onfailure => 'Unable to clean up work directory before compiling the kit' },
		'rm -rf "$@"', @files);
}

sub compile {
	my ($self, $name, $version, $outdir) = @_;

	$self->validate or return undef;
	$self->_prepare("$name-$version");

	run(
		{ onfailure => 'Unable to update kit.yml with version "$version"' },
		'echo "version: ${1}" | spruce merge "${2}/kit.yml" - > "${3}/${4}/kit.yml"',
		$version, $self->{root}, $self->{work}, $self->{relpath});

	run(
		{ onfailure => 'Unable to compile final kit tarball' },
		'tar -czf "$1/$3.tar.gz" -C "$2" "$3/"',
		$outdir, $self->{work}, $self->{relpath});

	return "$self->{relpath}.tar.gz";
}

1;

=head1 NAME

Genesis::Kit::Compiler

=head1 DESCRIPTION

The Compiler class encapsulates all of the rules and logic that go into
compiling a kit source directory into a distributable Genesis Kit tarball.
It includes facilities for validating the kit source, expunging files we
don't wish to distribute (other tarballs, ci/ directories, etc.), and
handles the naming and composition of the Kit archive.

This module is fully object-oriented, and does not export any procedural
functions or package variables.

    use Genesis::Kit::Compiler;

    my $cc = Genesis::Kit::Compiler->new("path/to/kit/src");
    if (!$cc->validate) {
      error "#R{Problems were found with your Kit source.}";
      exit 2;
    }

    my $v = '1.0.9';
    $cc->compile("my-kit", , ".");
    # file will be ./my-kit-1.0.9.tar.gz

=head1 METHODS

=head2 new($root)

Instantiate a new Kit Compiler, for compiling the source found in C<$root>.

=head2 validate()

Validate a Kit by inspecting its source code and defined metadata.

The following validations are performed:

=over

=item 1.

All kits must have a kit.yml with valid YAML in it.

=item 2.

The kit.yml file must provide values for the top-level C<name>, C<author>,
C<homepage>, and C<github> keys.

=item 3.

The C<hooks/> directory must exist.

=item 4.

Any present hooks must be executable files.

=item 5.

If defined, the C<genesis_min_version> value must be a valid semantic
version.

=back

=head2 compile($name, $version, $outdir)

Compiles a kit source directory into a distributable tarball, of the given
version.  Version is specified here, vs. in the kit.yml metadata, to enable
automation of release engineering via tools like Concourse.  Compilation
implciitly calls C<validate()> for you, so you don't need to do so
out-of-band.

The output tarball will be written to C<$outdir/$name-$version.tar.gz>, and
will bundle all files in the archive under the relative path
C<$name-$version/>.

=head2 CAVEATS

You cannot easily re-use one Kit Compiler to compile a different directory.
Several internal functions cache state that is only valid for a single root
source directory.  In practice this is not an issue, since for the most
part Genesis just uses this for the C<compile-kit> sub-command, which only
deals with a single Kit.
