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
	decode_json(Genesis::Run::get('spruce json "$1"', $file));
}

sub Load {
	my ($yaml) = @_;

	my $tmp = workdir();
	open my $fh, "|-", "spruce json >$tmp/yaml.json"
		or die "Failed to execute `spruce json': $!\n";
	print $fh $yaml;
	close $fh;

	return LoadFile("$tmp/yaml.json")
}

1;
