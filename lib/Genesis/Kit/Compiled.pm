package Genesis::Kit::Compiled;
use strict;
use warnings;

use base 'Genesis::Kit';
use Genesis;
use Genesis::Term;
use Genesis::Helpers;
use Archive::Tar;

sub new {
	my ($class, %opts) = @_;

	my $tar = $class->_validate_tar_archive(\%opts);
	my $obj =	bless({
		name     => $opts{name},
		version  => $opts{version},
		source   => $opts{archive},
		provider => $opts{provider},
		tar      => $tar,
	}, $class);

}

sub local_kits {
	my ($class, $provider, $path) = @_;
	$path ||= '.';
	$path =~ s{/$}{};

	my %kits;
	for (glob("$path/*")) {
		next unless m{/([^/]*)-(\d+(\.\d+(\.\d+([.-]rc[.-]?\d+)?)?)?).t(ar.)?gz$};
		my ($kit_name, $kit_version) = ($1, $2);
		my $kit = eval {
			$class->new(
				name     => $kit_name,
				version  => $kit_version,
				archive  => $_,
				provider => $provider
			);
		};
		if ($@) {
			warning("Skipping invalid kit archive %s: %s", $_, $@);
			next;
		}
		$kits{$kit_name}{$kit_version} = $kit;
	}
	return \%kits;
}

sub kit_bug {
	my ($self, @msg) = @_;
	my @errs = (
		csprintf(@msg),
		csprintf("#R{This is a bug in the %s kit.}", $self->id));

	my @authors;
	if ($self->metadata->{authors}) {
		@authors = @{$self->metadata->{authors}};
	} elsif ($self->metadata->{author}) {
		@authors = ($self->metadata->{author});
	}

	my $url = $self->metadata->{code} || '';
	if ($url =~ m/github/) {
		push @errs, csprintf("Please file an issue at #C{%s/issues}", $url);
	} elsif (@authors) {
		push @errs, "Please contact the author(s):";
		push @errs, "  - $_" for @authors;
	}

	$! = 2; die join("\n", @errs)."\n\n";
}

sub id {
	my ($self) = @_;
	return "$self->{name}/$self->{version}";
}

sub name {
	my ($self) = @_;
	return $self->{name};
}

sub version {
	my ($self) = @_;
	return $self->{version};
}

sub extract {
	my ($self) = @_;
	return if $self->{root};
	$self->{root} = workdir();
	my $basedir = sprintf("%s-%s/", $self->{name}, $self->{version});
	$self->{tar}->remove($basedir);
	$self->{tar}->setcwd($self->{root});
	for my $file (sort $self->{tar}->list_files) {
		$self->{tar}->extract_file($file, "$self->{root}/".($file =~ s{^$basedir}{}r));
	}
	Genesis::Helpers->write("$self->{root}/.helper");
	return 1;
}

### Private Class Methods
sub _validate_tar_archive {
	my($class, $opts) = @_;

	# --- Existing checks ---
	bail("Missing required option: archive") unless $opts->{archive};
	bail("Archive file does not exist: $opts->{archive}") unless -f $opts->{archive};

	# --- Check: File readability (permissions / SELinux) ---
	bail(
		"Kit archive file %s exists but cannot be read.\n\n".
		"Check file permissions and ensure the current user has read access.\n".
		"  File: %s\n".
		"  User: %s (uid %d)",
		$opts->{archive}, $opts->{archive}, scalar(getpwuid($>)), $>
	) unless -r $opts->{archive};

	# --- Check: Empty file (disk full / interrupted download) ---
	my $size = -s $opts->{archive};
	bail(
		"Kit archive file %s is empty (0 bytes).\n\n".
		"The download may have been interrupted or the disk was full.\n".
		"Remove the file and download the kit again.",
		$opts->{archive}
	) unless $size && $size > 0;

	# --- For .tar.gz / .tgz: validate content before Archive::Tar ---
	if ($opts->{archive} =~ /\.(tar\.gz|tgz)$/i) {

		open my $fh, '<:raw', $opts->{archive}
			or bail("Unable to read kit archive %s: %s", $opts->{archive}, $!);
		my $bytes_read = read($fh, my $header, 512);
		close $fh;

		# Check: HTML response saved as kit file (proxy / captive portal)
		if (defined($header) && $header =~ /<(!DOCTYPE|html|head|body)/i) {
			bail(
				"Kit archive file %s contains HTML instead of a gzip archive (%d bytes).\n\n".
				"A network proxy or captive portal likely intercepted the download\n".
				"and returned an HTML page instead of the kit file.\n\n".
				"Check network connectivity, proxy settings, and authentication.\n".
				"Then remove this file and re-download the kit.",
				$opts->{archive}, $size
			);
		}

		# Check: Gzip magic bytes
		unless (defined($header) && length($header) >= 2
				&& substr($header, 0, 2) eq "\x1f\x8b") {
			bail(
				"Kit archive file %s is not a valid gzip file (%d bytes).\n\n".
				"The file may be corrupted or was only partially downloaded.\n".
				"Remove it and download the kit again.\n".
				"  Expected: gzip magic bytes (1f 8b)\n".
				"  Got:      %s",
				$opts->{archive}, $size,
				join(' ', map { sprintf('%02x', ord($_)) }
					split('', substr($header // '', 0, 8)))
			);
		}

		# Check: Decompression module availability
		my $has_gunzip = eval { require IO::Uncompress::Gunzip; 1 };
		my $has_zlib   = eval { require IO::Zlib; 1 };
		unless ($has_gunzip || $has_zlib) {
			bail(
				"Cannot decompress kit archive %s: neither IO::Uncompress::Gunzip\n".
				"nor IO::Zlib is installed.\n\n".
				"Install a decompression module:\n".
				"  cpan install IO::Uncompress::Gunzip\n\n".
				"Or run 'genesis check' to verify all dependencies.",
				$opts->{archive}
			);
		}
	}

	# --- Phase B: Open archive with warning capture ---
	my @tar_warnings;
	my $tar = eval {
		local $SIG{__WARN__} = sub { push @tar_warnings, @_ };
		Archive::Tar->new($opts->{archive});
	};

	# Handle failure with version info
	if ($@ || !$tar) {
		my $details = "";
		$details .= $@ if $@;
		if (@tar_warnings) {
			$details .= "\n  " . join("  ", @tar_warnings);
		}
		bail(
			"Failed to read kit archive %s.\n\n".
			"The file may be corrupted or truncated. Remove it and\n".
			"download the kit again.\n".
			"  Archive::Tar %s, Perl %s\n".
			"  File size: %d bytes\n%s",
			$opts->{archive},
			Archive::Tar->VERSION, $],
			$size,
			$details
		);
	}

	my ($basedir, @o) = grep {$_ !~ m{/.}} map {$_->full_path() =~ s{/*$}{/}r} grep {$_->is_dir} $tar->get_files;
	bail("Archive file %s does not appear to be a valid Genesis kit (missing base directory)", $opts->{archive}) unless $basedir;
	my ($base_name, $base_version) = $basedir =~ m{^([^/]+)-(\d+(\.\d+(\.\d+([.-]rc[.-]?\d+)?)?)?)/$} if $basedir;
	if ($opts->{name} && $opts->{version}) {
		$opts->{version} =~ s/^v//; # Strip leading v if any
		bail("Archive file %s name/version (%s/%s) does not match provided name/version (%s/%s)",
			$opts->{archive}, $base_name // 'unknown', $base_version // 'unknown',
			$opts->{name}, $opts->{version}
		) if (!$base_name || !$base_version || $base_name ne $opts->{name} || $base_version ne $opts->{version});
	} elsif (!$base_name || !$base_version) {
		bail("Archive file %s does not appear to be a valid Genesis kit (missing base director 'name-version')", $opts->{archive});
	} else {
		# Use from archive
		$opts->{name} = $base_name;
		$opts->{version} = $base_version;
	}
	bail(
		"Archive file %s does not appear to be a valid Genesis kit (missing kit.yml in base directory %s)",
		$opts->{archive}, $basedir
	) unless $tar->contains_file("${basedir}kit.yml");

	# Note: Name/version validation is performed against the archive's
	# base directory structure (step 9 above). Parsing kit.yml here to
	# cross-check would add I/O overhead for minimal benefit, since the
	# directory name is the authoritative source during archive validation.
	# If kit.yml validation is needed, it should happen during extract().

	return $tar;
}



1;
