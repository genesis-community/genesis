package Genesis::Env::Secrets::Parser::FromKit;

use strict;
use warnings;

use parent ('Genesis::Env::Secrets::Parser');

use Genesis::Secret::DHParams;
use Genesis::Secret::Invalid;
use Genesis::Secret::UserProvided;
use Genesis::Secret::RSA;
use Genesis::Secret::Random;
use Genesis::Secret::SSH;
use Genesis::Secret::X509;
use Genesis::Secret::UUID;

use Genesis;

# Instance Methods
sub parse {
	my ($self,%opts) = @_;
	my @secrets = ();
	logger->info({pending =>1},
		"[[  - >>fetching secret definitions from kit defintion file ... "
	) if $opts{notify};

	bug(
		"No environment provided, and no kit metadata or features list were ".
		"passed in as options."
	) unless $self->env || ($opts{kit_metadata} && $opts{features});

	my $metadata = $opts{kit_metadata} // $self->env->dereferenced_kit_metadata;
	my $features = $opts{features} // [$self->env->features] // [];
	for my $feature ('base', @$features) {
		if (_validate_feature_block($metadata, 'certificates', $feature, \@secrets)) {
			while (my ($path, $data) = each(%{$metadata->{certificates}{$feature}||{}})) {
				push @secrets, $self->_parse_x509_secret_definition($path, $data, $feature);
			}
		}
		if (_validate_feature_block($metadata, 'provided', $feature, \@secrets)) {
			while (my ($path, $data) = each(%{$metadata->{provided}{$feature}||{}})) {
				push @secrets, $self->_parse_provided_secret_definition($path, $data, $feature);
			}
		}
		if (_validate_feature_block($metadata, 'credentials', $feature, \@secrets)) {
			while (my ($path, $data) = each(%{$metadata->{credentials}{$feature}||{}})) {
				push @secrets, $self->_parse_credential_definition($path, $data, $feature);
			}
		}
	}
	logger->info(
		"#%s{found %s}", scalar(@secrets) ? 'G' : 'B', scalar(@secrets)
	) if $opts{notify};
	return @secrets;
}

sub _parse_x509_secret_definition {
	my ($self, $path, $data, $feature) = @_;

	next unless defined($data);

	return _invalid_secret(
		"X.509 Certificate" => "Path cannot contain colons", $path, $data, $feature
	) if ($path =~ ':');

	return _invalid_secret(
		"X.509 Certificate" => "Expecting certificate specification in the form of a hash map",
		$path, $data, $feature
	) unless ref($data) eq 'HASH';

	return map {
		$self->_parse_x509_subpaths($path, $_, $data->{$_}, $feature)
	} keys %$data;
}

sub _parse_x509_subpaths {
	my ($self, $path, $subpath, $subdata, $feature) = @_;

	my $ext_path = "$path/$subpath";

	next unless defined($subdata);

	return _invalid_secret(
		"X.509 Certificate" => "Expecting hashmap, got "._ref_description($subdata),
		$ext_path, $subdata, $feature
	) unless ref($subdata) eq 'HASH';

	$subdata->{is_ca} = 1 if $subpath eq 'ca' && !exists($subdata->{is_ca});

	# In-the-wild POC conflict fix for cf-genesis-kit v1.8.0-v1.10.x
	$subdata->{signed_by} = "application/certs/ca"
		if ($subdata->{signed_by} || '') eq "base.application/certs.ca";

	return Genesis::Secret::X509->new(
		$ext_path,
		%$subdata,  # Blind passthrough -- may need to be generalized once Credhub variable parser is built
		base_path => $path,
		_feature => $feature
	);
}

sub _parse_provided_secret_definition {
	my ($self, $path, $data, $feature) = @_;

	next unless defined($data);

	return _invalid_secret(
		"User-Provided" => "Path cannot contain colons",
		$path, $data, $feature
	) if ($path =~ ':');

	return _invalid_secret(
		"User-Provided" => "Expecting hashmap, got "._ref_description($data),
		$path, $data, $feature
	) unless ref($data) eq 'HASH';

	my @secrets = ();
	if (($data->{type} //= 'generic') eq 'generic') {
		return _invalid_secret(
			"User-Provided" => "Missing or invalid 'keys' hash",
			$path, $data, $feature
		) unless ref($data->{keys}) eq 'HASH';

		for my $k (keys %{$data->{keys}}) {
			my $ext_path = "$path:$k";
			my $key_data = $data->{keys}{$k};
			if ($k =~ ':') {

				push @secrets, _invalid_secret(
					"User-Provided" => "Key cannot contain colons",
					$ext_path, $key_data, $feature
				);
				next;
			}
			push @secrets, Genesis::Secret::UserProvided->new(
				$ext_path,
				subtype   => $key_data->{type},
				sensitive => (defined($key_data->{sensitive}) ? ($key_data->{sensitive}?1:0) : 1),
				multiline => $key_data->{multiline}?1:0,
				prompt    => $key_data->{prompt} || "Value for $path $k",
				fixed     => $key_data->{fixed}?1:0,
				_feature  => $feature
			);
		}
	} else {
		return _invalid_secret(
			"User-Provided" => "Unknown provided type '$data->{type}'",
			$path, $data, $feature
		)
	}
	return @secrets;
}

sub _parse_credential_definition {
	my ($self, $path, $data, $feature) = @_;

	next unless defined($data);

	return _invalid_secret(
		"Credential" => "Path cannot contain colons",
		$path, $data, $feature
	) if ($path =~ ':');

	if (ref($data) eq 'HASH') {
		return map {$self->_parse_credential_key($path, $_, $data->{$_}, $feature)} (keys %$data);
	} elsif ($data =~ m/^(ssh|rsa)\s+(\d+)(\s+fixed)?$/) {
		my $type = "Genesis::Secret::".uc($1);
		return $type->new($path, size => $2, fixed => ($3 ? 1 : 0), _feature => $feature);
	} elsif ($data =~ m/^dhparams?\s+(\d+)(\s+fixed)?$/) {
		return Genesis::Secret::DHParams->new($path, size => $1, fixed => ($2 ? 1 : 0), _feature => $feature);
	} elsif ($data =~ m/^random .?$/) {
		return _invalid_secret(
			"Random" => "random password request for a path must be specified per key in a hashmap",
			$path, $data, $feature
		)
	} elsif ($data =~ m/^uuid .?$/) {
		return _invalid_secret(
			"UUID" => "UUID request for a path must be specified per key in a hashmap",
			$path, $data, $feature
		)
	} else {
		return _invalid_secret(
			"Unrecognized" => "Unrecognized request '$data'",
			$path, $data, $feature
		)
	}
}

sub _parse_credential_key {
	my ($self, $path, $key, $data, $feature) = @_;

	return _invalid_secret(
		"Credential" => "Key cannot contain colons",
		$path.":".$key, $data, $feature
	) if ($key =~ ':');

	my $ext_path = "$path:$key";
	if ($data =~ m/^random\b/) {
		if ($data =~ m/^random\s+(\d+)(\s+fmt\s+(\S+)(\s+at\s+(\S+))?)?(\s+allowed-chars\s+(\S+))?(\s+fixed)?$/) {
			return Genesis::Secret::Random->new(
				$ext_path,
				size        => $1,
				format      => $3,
				destination => $5,
				valid_chars => $7,
				fixed       => $8?1:0,
				_feature    => $feature
			);
		} else {
			return _invalid_secret(
				"Random" =>
					"Expected usage: random <size> [fmt <format> [at <key>]] [allowed-chars <chars>] [fixed]\n".
					"Got: $data",
				$ext_path, $data, $feature
			);
		}
	} elsif ($data =~ m/^uuid\b/) {
		if ($data =~ m/^uuid(?:\s+(v[1345]|time|md5|random|sha1))?(?:\s+namespace (?:([a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12})|(dns|url|oid|x500)))?(?:\s+name (.*?))?(\s+fixed)?$/i) {
			return Genesis::Secret::UUID->new(
				$ext_path,
				version   => uc($1||"v4"),
				namespace => $2 || ($3 ? "NS_".uc($3) : undef),
				name      => $4,
				fixed     => $5?1:0,
				_feature  => $feature
			);
		} else {
			return _invalid_secret(
				"UUID" =>
					"Expected usage: uuid [v1|time|v3|md5|v4|random|v5|sha1] ".
					"[namespace (dns|url|oid|x500|<UUID namespace>] [name <name>] ".
					"[fixed]\n".
					"Got: $data",
				$ext_path, $data, $feature
			);
		}
	} else {
		return _invalid_secret(
			"Random" => "Bad generate-password format '$data'",
			$ext_path, $data, $feature
		);
	}
}

sub _invalid_secret {
	Genesis::Secret::Invalid->new(
		$_[2],
		data     => $_[3],
		subject  => $_[0],
		errors   => ref($_[1]) eq 'ARRAY' ? $_[1] : [$_[1]],
		_feature => $_[4]
	);
}

sub _ref_description {
	my $val = shift;
	ref($val) ? lc(ref($val)) : defined($val) ? "'$val'" : '<null>'
}

sub _validate_feature_block {
	my ($data, $block, $feature, $secrets) = @_;
	return 0 unless defined($data->{$block}{$feature});
	return 1 if ref($data->{$block}{$feature}) eq 'HASH';


	my $subject = {
		certificates => 'X.509 Certificate',
		provided => "User-Provided",
		credentials => "Credentials"
	}->{$block};
	push @$secrets, _invalid_secret(
		 $subject =>
			"Expecting a hashmap, got "._ref_description($data->{$block}{$feature}),
		"$block/$feature"

	);
	return 0;
}

1;
# vim: fdm=marker:foldlevel=1:noet
