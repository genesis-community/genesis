package Genesis::IO;

use base 'Exporter';
our @EXPORT = qw/
	DumpJSON LoadFile Load
/;

use JSON::PP qw/decode_json encode_json/;
use Genesis::Utils;
use Genesis::Run;

sub DumpJSON {
	my ($file, $data) = @_;
	open my $fh, ">", $file or die "Unable to write to $file: $!\n";
	print $fh encode_json($data);
	close $fh;
}

sub LoadFile {
	my ($file) = @_;
	my ($out, $rc) = run('spruce json "$1"', $file);
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
