package Genesis::IO;

use base 'Exporter';
our @EXPORT = qw/
	DumpJSON DumpYAML LoadFile Load
/;

use JSON::PP qw/decode_json encode_json/;
use Genesis;

sub DumpJSON {
	my ($file, $data) = @_;
	open my $fh, ">", $file or die "Unable to write to $file: $!\n";
	print $fh encode_json($data);
	close $fh;
}

sub DumpYAML {
	my ($file, $data) = @_;
	my $i=1; while (-f "$file.$i.json") {$i++};
	my $tmpfile = "$file.$i.json";
	DumpJSON($tmpfile,$data);
	run('cat "$1" | spruce merge - > $2; rm "$1"', $tmpfile, $file);
}

sub LoadFile {
	my ($file) = @_;
	my ($out, $rc) = run({ stderr => 0 }, 'spruce json "$1"', $file);
	return $rc ? undef : decode_json($out);
}

sub Load {
	my ($yaml) = @_;

	my $tmp = workdir();
	open my $fh, ">", "$tmp/json.yml"
		or die "Unable to create tempfile for YAML conversion: $!\n";
	print $fh $yaml;
	close $fh;
	return LoadFile("$tmp/json.yml")
}

1;

=head1 NAME

Genesis::IO

=head1 DESCRIPTION

This module provides utilities for performing JSON / YAML input output.

=head1 FUNCTIONS

=head2 LoadFile($path)

Reads the contents of C<$path>, interprets it as YAML, and parses it into a
Perl hashref structure.  This leverages C<spruce>, so it can only be used on
YAML documents with top-level maps.  In practice, this limitation is hardly
a problem.

=head2 Load($yaml)

Interprets its argument as a string of YAML, and parses it into a Perl
hashref structure.  This leverages C<spruce>, so it can only be used on
YAML documents with top-level maps.  In practice, this limitation is hardly
a problem.

=cut
