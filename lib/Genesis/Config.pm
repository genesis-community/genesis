package Genesis::Config;
use strict;
use warnings;

use Genesis;

use JSON::PP ();
use Digest::SHA qw/sha1_hex/;
use File::Basename qw/dirname/;
use POSIX qw/strftime/;

### Class Constants {{{

use constant {
	TRUE  => JSON::PP::true,
	FALSE => JSON::PP::false,
};

# }}}

### Class Methods {{{

# new - return a bare config object {{{
sub new {
	my ($class,$path,$autosave) = @_;

	# TODO: specify a schema for validation

	return bless({
			path => $path,
			persistant_signature => undef,
			autosave => $autosave ? 1 : 0,
			contents => {},
		}, $class);
}

# }}}
# }}}

# Instance Methods {{{

# exists - returns true if the configuration file exists on the filesystem {{{
sub exists {
	-f $_[0]->{path}
}

# }}}
# loaded - returns true if the file has been initialized (loaded from or saved to disk) {{{
sub loaded {
	return 1 if defined($_[0]->{persistant_signature});
}

# }}}
# changed - returns true if the local representation differs from the filesystem {{{
sub changed {
	my $self = shift;
	($self->{persistant_signature}||'') ne $self->_signature;
}

# }}}
# get - read a value from the configuration {{{
sub get {
	my ($self,$key,$default,$set_if_missing) = @_;

	# Caching
	$key ||= '';
	return $self->{cache}{$key} if exists($self->{cache}{$key});

	my ($value,$found) = struct_lookup($self->_contents,$key,$default);
	if ($set_if_missing && ! defined($found)) {
		$self->set($key,$value);
		$found = $key;
	}
	$self->{cache}{$key} = $value if $found;
	return $value;
}

# }}}
# set - write a value to the configuration {{{
sub set {
	my ($self, $key, $value, $save) = @_;
	# TODO: Validate key and value against schema

	delete($self->{cache}{$_}) for (grep {$_ =~ /^$key($|[\.\[])/} keys(%{$self->{cache}}));
	struct_set_value($self->_contents,$key,$value);
	$self->save if $self->changed && ($save || $self->{autosave});
	return $self->changed;
}

# }}}
# clear - remove a key from the configuration {{{
sub clear {
	my ($self, $key, $save) = @_;
	# TODO: Delete entire structure if key is undefined, or should that be an error?
	# TODO: Validate key and value against schema

	delete($self->{cache}{$_}) for (grep {$_ =~ /^$key($|[\.\[])/} keys(%{$self->{cache}}));
	struct_set_value($self->_contents,$key,1);
	$self->save if $self->changed && ($save || $self->{autosave});
	return $self->changed;
}

# }}}
# save - save the configuration to the filesystem {{{
sub save {
	my ($self) = @_;

	my $tmp = workdir();
	my $i=1; while (-f "$tmp/$i.json") {$i++};
	open my $fh, ">", "$tmp/$i.json"
		or bail "Unable to create tempfile for YAML conversion: $!";
	print $fh JSON::PP->new->canonical->encode($self->_contents);
	close $fh;
	my ($out,$rc,$err) = run(
		{stderr => 0},
		'cat "$1" | spruce merge --skip-eval - ; rm "$1"',
		"$tmp/$i.json"
	);
	bail(
		"Failed to convert configuration file to yaml: %s",
		$self->{path}, $err
	) if $rc;
	mkdir_or_fail(dirname($self->{path}));

	my $now = strftime("%Y-%m-%d at %H:%M:%S UTC", gmtime());
	open my $fh2, ">", $self->{path}
		or bail(
			"Failed to write configuration file to %s: %s",
			$self->{path}, $!
		);
	printf $fh2 "---\n# This file is generated by Genesis - do not edit manually.\n# Last updated by %s on %s\n\n", $ENV{USER}, $now;
	print $fh2 $out;
	close $fh2;
	$self->{persistant_signature} = $self->_signature;
}

# }}}
# }}}

### Instance Private Methods {{{

# _contents - the contents of the configuration object {{{
sub _contents {
	my ($self) = @_;
	$self->_load() unless ($self->loaded) || (! $self->exists && exists($self->{contents}));
	return $self->{contents}
}

# }}}
# _load - load the contents of the configuration file from disk {{{
sub _load {
	my ($self) = @_;
	if ($self->exists) {
		eval {
			$self->{contents} = load_yaml_file($self->{path});
		};
		bail("Failed to load %s: %s", $self->{path}, $@) if ($@ || ! $self->{contents});
		$self->{persistant_signature} = $self->_signature;
	} else {
		$self->{contents} = {};
		$self->{save} if $self->{autosave};
	}
}

# }}}
# _signature - generate a signature for the current in-memory contents {{{
sub _signature {
	sha1_hex(JSON::PP->new->canonical->encode($_[0]->{contents}))
}
# }}}
# }}}
1;
# vim: fdm=marker:foldlevel=1:noet
