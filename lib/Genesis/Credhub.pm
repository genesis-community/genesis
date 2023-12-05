package Genesis::Credhub;
use strict;
use warnings;

use Genesis;
use Genesis::UI;
use JSON::PP qw/decode_json encode_json/;
use UUID::Tiny ();

### Class Methods {{{

# new - raw instantiation of a credhub object {{{
sub new {
	my ($class, $name, $base, $url, $username, $password, $ca_cert) = @_;
	return bless({
		name     => $name,
		base     => $base,
		url      => $url,
		username => $username,
		password => $password,
		ca_cert  => $ca_cert,
	}, $class)
}
# }}}
# }}}

### Instance Methods {{{

sub env {
	my $self = shift;
	return {
		CREDHUB_SERVER  => $self->{url},
		CREDHUB_CLIENT  => $self->{username},
		CREDHUB_SECRET  => $self->{password},
		CREDHUB_CA_CERT => $self->{ca_cert}
	};
}

sub has {
	return defined(shift->get(@_));
}

sub get {
	my ($self,$path,$key) = @_;
	my $results = $self->data($path);
	return defined($key) ? $results->{value}->{$key} : $results->{value};
}

sub data {
	my ($self,$path) = @_;
	return scalar(read_json_from(run({
			env => $self->env()
		},
		'credhub', 'get', '-j', '-n', $self->_full_path($path)
	)));
}

sub set {
	my ($self, $path, $value, $type) = @_;
	my @args = ();

	$type ||= (defined($value) && ref($value)) ? 'json' : 'value';
	if ($type eq 'certificate') {
		my @valid_keys = qw/certificate private_key root root_path/;
		my ($unused,$used,$invalid) = compare_arrays \@valid_keys, [keys %$value];
		my ($missing, $provided, $optional) = compare_arrays [qw/certificate private_key/], $used;

		# Need certificate and private_key, and one of ca or root_path.
		bail(
			"Invalid parameters specified for creating a CredHub certificate value: ".
			join(', ',@$invalid)
		) if @$invalid;
		bail(
			"You must supply either the certificate and the public_key when creating ".
			"a CredHub certificate value."
		) if @$missing;
		bail(
			"You must supply either the root ca certificate (root) or the CredHub path ".
			"to the root ca (root_path) when creating a certificate, but not both."
		) if scalar(@$optional) != 1;

		push @args, '-c', $value->{certificate};
		push @args, '-p', $value->{private_key};
		push @args, '-r', $value->{root} if defined($value->{root});
		push @args, '-m', $value->{root_path} if defined($value->{root_path});

	} elsif ($type eq 'ssh' || $type eq 'rsa') {
		my @valid_keys = qw/public_key private_key/;
		my ($missing,$provided,$invalid) = compare_arrays \@valid_keys, [keys %$value];

		bail(
			"Invalid parameters specified for creating a CredHub %s value: %s",
			uc($type), join(', ',@$invalid)
		) if @$invalid;
		bail(
			"You must supply the %s  when creating a Credhub %s value",
			sentence_join(@valid_keys), uc($type)
		) if @$missing;

		push @args, '-u', $value->{public_key};
		push @args, '-p', $value->{private_key};

	} elsif ($type eq 'user' || $type eq 'password') {
		my @valid_keys = ('password');
		push @valid_keys, 'username' if $type eq 'user';
		my ($missing,$provided,$invalid) = compare_arrays \@valid_keys, [keys %$value];

		bail(
			"Invalid parameters specified for creating a CredHub %s value: %s",
			uc($type), join(', ',@$invalid)
		) if @$invalid;
		bail(
			"You must supply the %s  when creating a Credhub %s value",
			sentence_join(@valid_keys), uc($type)
		) if @$missing;

		push @args, '-z', $value->{username} if defined($value->{username});
		push @args, '-w', $value->{password};

	} elsif ($type eq 'json') {
		bail(
			"You must specify a HASH or an ARRAY as the value when creating a CredHub ".
			"json value"
		) unless ref($value) =~ /^(ARRAY|HASH)$/;
		push @args, '-v', encode_json($value);

	} elsif ($type eq 'value') {
		bail(
			"You must specify a HASH or an ARRAY as the value when creating a CredHub ".
			"json value"
		) unless defined($value) and ref($value) eq '';
		push @args, '-v', $value;

	} else {
		bail(
			"Unknown CredHub type: $type - expecting one of: certificate, rsa, ssh, ".
			"user, password, json, or value"
		);
	}
	unshift @args, "-n", $self->_full_path($path), "-t", $type;
	my ($out,$rc, $err) =run({
			env => $self->env()
		},
		'credhub', 'set', '-j', @args
	);
	bail(
		"Could not create the Credhub %s value:\n%s\n[Exit Code: %s]",
		$type,$out,$rc
	) if $rc;
	my $result = read_json_from($out, $rc, $err);
	return ($result->{id});
}

sub paths {
	my ($self,$filter) = @_;
	my @filter = ();
	if (!  defined($filter)) {
		push(@filter, '-n', $self->{base}.'/');
	} elsif ($filter && ref($filter) eq "") {
		push(@filter, '-n', $self->_full_path($filter));
	}

	my $paths = read_json_from(run({
			env => $self->env()
		},
		'credhub', 'find', '-j', @filter
	));
	return
	  grep {ref($filter) ne "Regexp" || $_ =~ $filter}
	  map {$_->{name}}
		@{$paths->{credentials}};
}

sub keys {
	bug "Genesis::Credhub::keys method not supported";
}

sub delete {
	my ($self,$name) = @_;
	return scalar(read_json_from(run({
			env => $self->env()
		},
		'credhub', 'delete', '-j', '--name', $self->_full_path($name)
	)));
}

sub delete_all {
	my ($self,$path) = @_;
	return scalar(read_json_from(run({
			env => $self->env()
		},
		'credhub', 'delete', '-j', '--path', $self->_full_path($path)
	)));
}

sub query {
	my ($self,$path,%params) = @_;
	
	my @args;
	push @args, '-X', uc(delete($params{_method}))
		if defined $params{_method};
	push @args, '-d', delete($params{data})
		if defined $params{_data};
	# TODO: extract uri-encoded query params out of %params
	return scalar(read_json_from(run({
			env => $self->env()
		},
		'credhub', 'curl', '--path', "$path", @args
	)));
}

sub _full_path {
	my ($self,$path) = @_;
	return $self->{base} unless $path;
	return $path if ($path =~ /^\//);
	return ($self->{base}).'/'.$path;
}

# TODO: export, import

# }}}
1
